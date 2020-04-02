using LanguageServer;
using Gee;

class Vls.Request : Object {
    private int64? int_value;
    private string? string_value;
    private string? method;

    public Request (Variant id, string? method = null) {
        assert (id.is_of_type (VariantType.INT64) || id.is_of_type (VariantType.STRING));
        if (id.is_of_type (VariantType.INT64))
            int_value = (int64) id;
        else
            string_value = (string) id;
        this.method = method;
    }

    public string to_string () {
        string id_string = int_value != null ? int_value.to_string () : string_value;
        return id_string + (method != null ? @":$method" : "");
    }

    public static uint hash (Request req) {
        if (req.int_value != null)
            return GLib.int64_hash (req.int_value);
        else
            return GLib.str_hash (req.string_value);
    }

    public static bool equal (Request reqA, Request reqB) {
        if (reqA.int_value != null) {
            assert (reqB.int_value != null);
            return reqA.int_value == reqB.int_value;
        } else {
            assert (reqB.string_value != null);
            return reqA.string_value == reqB.string_value;
        }
    }
}

class Vls.Server : Object {
    private static bool received_signal = false;
    Jsonrpc.Server server;
    MainLoop loop;

    HashTable<string, NotificationHandler> notif_handlers;
    HashTable<string, CallHandler> call_handlers;
    InitializeParams init_params;

    const uint check_update_context_period_ms = 100;
    const int64 update_context_delay_inc_us = 1000;
    const int64 update_context_delay_max_us = 1000 * 1000;
    const uint wait_for_context_update_delay_ms = 200;

    Project project;

#if PARSE_SYSTEM_GIRS
    /**
     * Contains documentation from found GIR files.
     */
    GirDocumentation documentation;
#endif
    HashSet<Request> pending_requests;

    bool shutting_down = false;

    bool is_initialized = false;

    /**
     * The global cancellable object
     */
    static Cancellable cancellable = new Cancellable ();

    [CCode (has_target = false)]
    delegate void NotificationHandler (Vls.Server self, Jsonrpc.Client client, Variant @params);

    [CCode (has_target = false)]
    delegate void CallHandler (Vls.Server self, Jsonrpc.Server server, Jsonrpc.Client client, string method, Variant id, Variant @params);

    private void log_handler (string? log_domain, LogLevelFlags log_levels, string message) {
        string level = "";

        if ((log_levels & LogLevelFlags.LEVEL_MASK) == LogLevelFlags.LEVEL_MASK)
            level = "-ALL";
        else if ((log_levels & LogLevelFlags.LEVEL_CRITICAL) != 0)
            level = "-CRITICAL";
        else if ((log_levels & LogLevelFlags.LEVEL_DEBUG) != 0)
            level = "-DEBUG";
        else if ((log_levels & LogLevelFlags.LEVEL_ERROR) != 0)
            level = "-ERROR";
        else if ((log_levels & LogLevelFlags.LEVEL_INFO) != 0)
            level = "-INFO";
        else if ((log_levels & LogLevelFlags.LEVEL_MESSAGE) != 0)
            level = "-MESSAGE";
        else if ((log_levels & LogLevelFlags.LEVEL_WARNING) != 0)
            level = "-WARNING";
        printerr ("%s: %s\n", log_domain == null ? @"vls$level" : log_domain, message);
    }

    uint[] g_sources = {};
    ulong event;

    static construct {
        Process.@signal (ProcessSignal.INT, () => {
            if (!Server.received_signal)
                cancellable.cancel ();
            Server.received_signal = true;
        });
        Process.@signal (ProcessSignal.TERM, () => {
            if (!Server.received_signal)
                cancellable.cancel ();
            Server.received_signal = true;
        });
    }

    public Server (MainLoop loop) {
        // capture logging
        Log.set_handler (null, LogLevelFlags.LEVEL_MASK, log_handler);
        Log.set_handler ("jsonrpc-server", LogLevelFlags.LEVEL_MASK, log_handler);

        this.loop = loop;
        this.server = new Jsonrpc.Server ();

        // hack to prevent other things from corrupting JSON-RPC pipe:
        // create a new handle to stdout, and close the old one (or move it to stderr)
#if WINDOWS
        var new_stdout_fd = Windows._dup (Posix.STDOUT_FILENO);
        Windows._close (Posix.STDOUT_FILENO);
        Windows._dup2 (Posix.STDERR_FILENO, Posix.STDOUT_FILENO);
        void* new_stdin_handle = Windows._get_osfhandle (Posix.STDIN_FILENO);
        void* new_stdout_handle = Windows._get_osfhandle (new_stdout_fd);

        // we can't use the names 'stdin' or 'stdout' for these variables
        // since it causes build problems for mingw-w64-x86_64-gcc
        var input_stream = new Win32InputStream (new_stdin_handle, false);
        var output_stream = new Win32OutputStream (new_stdout_handle, false);
#else
        var new_stdout_fd = Posix.dup (Posix.STDOUT_FILENO);
        Posix.close (Posix.STDOUT_FILENO);
        Posix.dup2 (Posix.STDERR_FILENO, Posix.STDOUT_FILENO);

        var input_stream = new UnixInputStream (Posix.STDIN_FILENO, false);
        var output_stream = new UnixOutputStream (new_stdout_fd, false);

        // set nonblocking
        try {
            if (!Unix.set_fd_nonblocking (Posix.STDIN_FILENO, true)
             || !Unix.set_fd_nonblocking (new_stdout_fd, true))
             error ("could not set pipes to nonblocking.\n");
        } catch (Error e) {
            debug ("failed to set FDs to nonblocking");
            loop.quit ();
            return;
        }
#endif

        // shutdown if/when we get a signal
        g_sources += Timeout.add (1 * 1000, () => {
            if (Server.received_signal) {
                shutdown_real ();
                return Source.REMOVE;
            }
            return !this.shutting_down;
        });

        server.accept_io_stream (new SimpleIOStream (input_stream, output_stream));

#if WITH_JSONRPC_GLIB_3_30
        event = server.client_closed.connect (client => {
            shutdown_real ();
        });
#endif

        notif_handlers = new HashTable<string, NotificationHandler> (str_hash, str_equal);
        call_handlers = new HashTable<string, CallHandler> (str_hash, str_equal);

        pending_requests = new HashSet<Request> (Request.hash, Request.equal);

        server.notification.connect ((client, method, @params) => {
            debug (@"Got notification! $method");
            if (!is_initialized) {
                debug ("Server is not initialized");
            } else if (notif_handlers.contains (method))
                ((NotificationHandler) notif_handlers[method]) (this, client, @params);
            else
                debug (@"no notification handler for $method");
        });

        server.handle_call.connect ((client, method, id, @params) => {
            debug (@"Got call! $method");
            if (!is_initialized && !(method == "initialize" ||
                                     method == "shutdown" ||
                                     method == "exit")) {
                debug ("Server is not initialized");
                return false;
            } else if (call_handlers.contains (method)) {
                ((CallHandler) call_handlers[method]) (this, server, client, method, id, @params);
                return true;
            } else {
                debug (@"no call handler for $method");
                return false;
            }
        });

        call_handlers["initialize"] = this.initialize;
        call_handlers["shutdown"] = this.shutdown;
        notif_handlers["exit"] = this.exit;

        call_handlers["textDocument/definition"] = this.textDocumentDefinition;
        notif_handlers["textDocument/didOpen"] = this.textDocumentDidOpen;
        notif_handlers["textDocument/didClose"] = this.textDocumentDidClose;
        notif_handlers["textDocument/didChange"] = this.textDocumentDidChange;
        call_handlers["textDocument/documentSymbol"] = this.textDocumentDocumentSymbol;
        call_handlers["textDocument/completion"] = this.textDocumentCompletion;
        call_handlers["textDocument/signatureHelp"] = this.textDocumentSignatureHelp;
        call_handlers["textDocument/hover"] = this.textDocumentHover;
        call_handlers["textDocument/references"] = this.textDocumentReferences;
        call_handlers["textDocument/documentHighlight"] = this.textDocumentReferences;
        call_handlers["textDocument/implementation"] = this.textDocumentImplementation;
        call_handlers["workspace/symbol"] = this.workspaceSymbol;
        notif_handlers["$/cancelRequest"] = this.cancelRequest;

        debug ("Finished constructing");
    }

    // a{sv} only
    public Variant buildDict (...) {
        var builder = new VariantBuilder (new VariantType ("a{sv}"));
        var l = va_list ();
        while (true) {
            string? key = l.arg ();
            if (key == null) {
                break;
            }
            Variant val = l.arg ();
            builder.add ("{sv}", key, val);
        }
        return builder.end ();
    }

    void showMessage (Jsonrpc.Client client, string message, MessageType type) {
        if (type == MessageType.Error)
            warning (message);
        try {
            client.send_notification ("window/showMessage", buildDict (
                type: new Variant.int16 (type),
                message: new Variant.string (message)
            ), cancellable);
        } catch (Error e) {
            debug (@"showMessage: failed to notify client: $(e.message)");
        }
    }

    void initialize (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        init_params = Util.parse_variant<InitializeParams> (@params);

        File root_dir;
        if (init_params.rootUri != null)
            root_dir = File.new_for_uri (init_params.rootUri);
        else if (init_params.rootPath != null)
            root_dir = File.new_for_path (init_params.rootPath);
        else
            root_dir = File.new_for_path (Environment.get_current_dir ());
        if (!root_dir.is_native ()) {
            showMessage (client, "Non-native files not supported", MessageType.Error);
            error ("Non-native files not supported");
        }
        string root_path = Util.realpath ((!) root_dir.get_path ());
        debug (@"[initialize] root path is $root_path");

        var meson_file = root_dir.get_child ("meson.build");
        // TODO: autotools, make(?), cmake(?), default backend
        if (meson_file.query_exists (cancellable)) {
            try {
                project = new MesonProject (root_path, cancellable);
            } catch (Error e) {
                showMessage (client, @"Failed to initialize Meson project - $(e.message)", MessageType.Error);
                project = new DefaultProject (root_path);       // fallback
            }
        } else {
            project = new DefaultProject (root_path);
            var cmake_file = root_dir.get_child ("CMakeLists.txt");
            var autogen_sh = root_dir.get_child ("autogen.sh");

            if (cmake_file.query_exists (cancellable))
                showMessage (client, @"CMake build system is not currently supported. Only Meson is. See https://github.com/benwaffle/vala-language-server/issues/73", MessageType.Warning);
            if (autogen_sh.query_exists (cancellable))
                showMessage (client, @"Autotools build system is not currently supported. Consider switching to Meson.", MessageType.Warning);
        }

        try {
            project.build_if_stale (cancellable);
        } catch (Error e) {
            warning ("[initialize] failed to build project - %s", e.message);
            reply_null (id, client, method);
            showMessage (client, @"failed to build project - $(e.message)", MessageType.Error);
            return;
        }

#if PARSE_SYSTEM_GIRS
        // create documentation (compiles GIR files too)
        documentation = new GirDocumentation (project.get_packages ());
#endif

        // respond
        try {
            client.reply (id, buildDict (
                capabilities: buildDict (
                    textDocumentSync: new Variant.int16 (TextDocumentSyncKind.Incremental),
                    definitionProvider: new Variant.boolean (true),
                    documentSymbolProvider: new Variant.boolean (true),
                    completionProvider: buildDict(
                        triggerCharacters: new Variant.strv (new string[] {".", ">"})
                    ),
                    signatureHelpProvider: buildDict(
                        triggerCharacters: new Variant.strv (new string[] {"(", ","})
                    ),
                    hoverProvider: new Variant.boolean (true),
                    referencesProvider: new Variant.boolean (true),
                    documentHighlightProvider: new Variant.boolean (true),
                    implementationProvider: new Variant.boolean (true),
                    workspaceSymbolProvider: new Variant.boolean (true)
                ),
                serverInfo: buildDict (
                    name: new Variant.string ("Vala Language Server"),
                    version: new Variant.string (Config.version)
                )
            ), cancellable);
        } catch (Error e) {
            error (@"[initialize] failed to reply to client: $(e.message)");
        }

        // build and publish diagnostics
        try {
            debug ("Building project ...");
            project.build_if_stale ();
            debug ("Publishing diagnostics ...");
            foreach (var compilation in project.get_compilations ())
                publishDiagnostics (compilation, client);
        } catch (Error e) {
            showMessage (client, @"Failed to build project - $(e.message)", MessageType.Error);
        }

        // listen for context update requests
        update_context_client = client;
        g_sources += Timeout.add (check_update_context_period_ms, () => {
            check_update_context ();
            return !this.shutting_down;
        });

        is_initialized = true;
    }

    void cancelRequest (Jsonrpc.Client client, Variant @params) {
        Variant? id = @params.lookup_value ("id", null);
        if (id == null)
            return;

        var req = new Request (id);
        if (pending_requests.remove (req))
            debug (@"[cancelRequest] cancelled request $req");
        else
            debug (@"[cancelRequest] request $req not found");
    }

    void reply_null (Variant id, Jsonrpc.Client client, string method) {
        try {
            client.reply (id, new Variant.maybe (VariantType.VARIANT, null), cancellable);
        } catch (Error e) {
            debug (@"[$method] failed to reply to client: $(e.message)");
        }
    }

    void textDocumentDidOpen (Jsonrpc.Client client, Variant @params) {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);

        string? uri         = (string) document.lookup_value ("uri",        VariantType.STRING);
        string languageId   = (string) document.lookup_value ("languageId", VariantType.STRING);
        string fileContents = (string) document.lookup_value ("text",       VariantType.STRING);

        if (languageId != "vala" && languageId != "genie") {
            warning (@"[textDocument/didOpen] $languageId file sent to vala language server");
            return;
        }

        if (uri == null) {
            warning (@"[textDocument/didOpen] null URI sent to vala language server");
            return;
        }

        try {
            project.open (uri, cancellable);
        } catch (Error e) {
            warning ("[textDocument/didOpen] failed to open %s - %s", uri, e.message);
            return;
        }

        foreach (Pair<Vala.SourceFile, Compilation> doc_w_bt in project.lookup_compile_input_source_file (uri)) {
            var doc = doc_w_bt.first;
            if (doc is TextDocument) {
                debug (@"[textDocument/didOpen] opened $(Uri.unescape_string (uri))");
                if (doc.content == null || doc.content != fileContents)
                    doc.content = fileContents;
                request_context_update (client);
                debug (@"[textDocument/didOpen] requested context update");
            } else {
                debug (@"[textDocument/didOpen] opened read-only $(Uri.unescape_string (uri))");
            }
        }
    }

    void textDocumentDidClose (Jsonrpc.Client client, Variant @params) {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);
        string? uri         = (string) document.lookup_value ("uri",        VariantType.STRING);

        if (uri == null) {
            warning (@"[textDocument/didClose] null URI sent to vala language server");
            return;
        }

        try {
            project.close (uri);
            request_context_update (client);
        } catch (Error e) {
            warning ("[textDocument/didClose] failed to close %s - %s", uri, e.message);
        }
    }

    Jsonrpc.Client? update_context_client = null;
    int64 update_context_requests = 0;
    int64 update_context_time_us = 0;

    void textDocumentDidChange (Jsonrpc.Client client, Variant @params) {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);
        var changes = @params.lookup_value ("contentChanges", VariantType.ARRAY);

        var uri = (string) document.lookup_value ("uri", VariantType.STRING);
        var version = (int64) document.lookup_value ("version", VariantType.INT64);

        foreach (Pair<Vala.SourceFile, Compilation> pair in project.lookup_compile_input_source_file (uri)) {
            var source_file = pair.first;
            if (source_file.content == null) {
                error (@"[textDocument/didChange] source content is null!");
            }

            if (!(source_file is TextDocument)) {
                debug (@"[textDocument/didChange] Ignoring change to system file");
                return;
            }

            var source = (TextDocument) source_file;
            if (source.version >= version) {
                debug (@"[textDocument/didChange] rejecting outdated version of $uri");
                return;
            }

            // update the document
            var iter = changes.iterator ();
            Variant? elem = null;
            var sb = new StringBuilder (source.content);
            while ((elem = iter.next_value ()) != null) {
                var changeEvent = Util.parse_variant<TextDocumentContentChangeEvent> (elem);

                if (changeEvent.range == null) {
                    sb.assign (changeEvent.text);
                } else {
                    var start = changeEvent.range.start;
                    var end = changeEvent.range.end;
                    size_t pos_begin = Util.get_string_pos (sb.str, start.line, start.character);
                    size_t pos_end = Util.get_string_pos (sb.str, end.line, end.character);
                    sb.erase ((ssize_t) pos_begin, (ssize_t) (pos_end - pos_begin));
                    sb.insert ((ssize_t) pos_begin, changeEvent.text);
                }
            }
            source.content = sb.str;
            source.last_updated = new DateTime.now ();
            source.version = (int) version;

            request_context_update (client);
        }
    }

    void request_context_update (Jsonrpc.Client client) {
        update_context_client = client;
        update_context_requests += 1;
        int64 delay_us = int64.min (update_context_delay_inc_us * update_context_requests, update_context_delay_max_us);
        update_context_time_us = get_monotonic_time () + delay_us;
        debug (@"Context(s) update (re-)scheduled in $((int) (delay_us / 1000)) ms");
    }

    /** 
     * Reconfigure the project if needed, and check whether we need to rebuild
     * the project if we have context update requests.
     */
    void check_update_context () {
        try {
            if (project.reconfigure_if_stale (cancellable))
                request_context_update (update_context_client);
        } catch (Error e) {
            warning ("failed to reconfigure stale project: %s", e.message);
        }

        if (update_context_requests > 0 && get_monotonic_time () >= update_context_time_us) {
            debug ("updating contexts and publishing diagnostics...");
            update_context_requests = 0;
            update_context_time_us = 0;
            try {
                project.build_if_stale (cancellable);
                foreach (var compilation in project.get_compilations ())
                    /* This must come after the resetting of the two variables above,
                     * since it's possible for publishDiagnostics to eventually call
                     * one of our JSON-RPC callbacks through g_main_context_iteration (),
                     * if we get a new message while sending the textDocument/publishDiagnostics
                     * notifications. */
                    publishDiagnostics (compilation, update_context_client);
            } catch (Error e) {
                warning ("Failed to rebuild project: %s", e.message);
            }
        }
    }

    delegate void OnContextUpdatedFunc (bool request_cancelled);

    /**
     * Rather than satisfying all requests in `check_update_context ()`,
     * to avoid race conditions, we have to spawn a timeout to check for 
     * the right conditions to call `on_context_updated_func ()`.
     */
    void wait_for_context_update (Variant id, owned OnContextUpdatedFunc on_context_updated_func) {
        // we've already updated the context
        if (update_context_requests == 0)
            on_context_updated_func (false);
        else {
            var req = new Request (id);
            if (!pending_requests.add (req))
                debug (@"Request ($req): request already in pending requests, this should not happen");
            else
                debug (@"Request ($req): added request to pending requests");
            wait_for_context_update_aux (req, (owned) on_context_updated_func);
        }
    }

    /**
     * Execute `on_context_updated_func ()` or wait.
     */
    void wait_for_context_update_aux (Request req, owned OnContextUpdatedFunc on_context_updated_func) {
        // we've already updated the context
        if (update_context_requests == 0) {
            if (!pending_requests.remove (req)) {
                debug (@"Request ($req): context updated but request cancelled");
                on_context_updated_func (true);
            } else {
                debug (@"Request ($req): context updated");
                on_context_updated_func (false);
            }
        } else {
            Timeout.add (wait_for_context_update_delay_ms, () => {
                if (pending_requests.contains (req))
                    wait_for_context_update_aux (req, (owned) on_context_updated_func);
                else {
                    debug (@"Request ($req): cancelled before context update");
                    on_context_updated_func (true);
                }
                return Source.REMOVE;
            });
        }
    }

    void publishDiagnostics (Compilation target, Jsonrpc.Client client) {
        var files_not_published = new HashSet<Vala.SourceFile> (Util.source_file_hash, Util.source_file_equal);
        var diags_without_source = new Json.Array ();

        debug ("publishing diagnostics for Compilation target %s", target.id);

        foreach (var file in target.code_context.get_source_files ())
            files_not_published.add (file);

        var doc_diags = new HashMap<Vala.SourceFile, Json.Array> ();

        target.reporter.messages.foreach (err => {
            if (err.loc == null) {
                diags_without_source.add_element (Json.gobject_serialize (new Diagnostic () {
                    severity = err.severity,
                    message = err.message
                }));
                return;
            }
            assert (err.loc.file != null);
            if (!(err.loc.file in target.code_context.get_source_files ())) {
                warning (@"diagnostic has source not in compilation! - $(err.message)");
                return;
            }

            var diag = new Diagnostic () {
                range = new Range () {
                    start = new Position () {
                        line = err.loc.begin.line - 1,
                        character = err.loc.begin.column - 1
                    },
                    end = new Position () {
                        line = err.loc.end.line - 1,
                        character = err.loc.end.column
                    }
                },
                severity = err.severity,
                message = err.message
            };

            var node = Json.gobject_serialize (diag);
            if (!doc_diags.has_key (err.loc.file))
                doc_diags[err.loc.file] = new Json.Array ();
            doc_diags[err.loc.file].add_element (node);
        });

        // at the end, report diags for each source file
        foreach (var entry in doc_diags.entries) {
            Variant diags_variant_array;
            var gfile = File.new_for_path (entry.key.filename);

            files_not_published.remove (entry.key);
            try {
                diags_variant_array = Json.gvariant_deserialize (
                    new Json.Node.alloc ().init_array (entry.value),
                    null);
            } catch (Error e) {
                warning (@"[publishDiagnostics] failed to deserialize diags for `$(gfile.get_uri ())': $(e.message)");
                continue;
            }
            try {
                client.send_notification (
                    "textDocument/publishDiagnostics",
                    buildDict (
                        uri: new Variant.string (gfile.get_uri ()),
                        diagnostics: diags_variant_array
                    ),
                    cancellable);
            } catch (Error e) {
                debug (@"[publishDiagnostics] failed to notify client: $(e.message)");
            }
        }

        foreach (var entry in files_not_published) {
            var gfile = File.new_for_path (entry.filename);
            try {
                client.send_notification (
                    "textDocument/publishDiagnostics",
                    buildDict (
                        uri: new Variant.string (gfile.get_uri ()),
                        diagnostics: new Variant.array (VariantType.VARIANT, new Variant[]{})
                    ),
                    cancellable);
            } catch (Error e) {
                debug (@"[publishDiagnostics] failed to publish empty diags for $(gfile.get_uri ()): $(e.message)");
            }
        }

        try {
            Variant diags_wo_src_variant_array = Json.gvariant_deserialize (
                new Json.Node.alloc ().init_array (diags_without_source),
                null);
            client.send_notification (
                "textDocument/publishDiagnostics",
                buildDict (
                    diagnostics: diags_wo_src_variant_array
                ),
                cancellable);
        } catch (Error e) {
            debug (@"[publishDiagnostics] failed to publish diags without source: $(e.message)");
        }
    }

    Vala.CodeNode get_best (FindSymbol fs, Vala.SourceFile file) {
        Vala.CodeNode? best = null;

        foreach (var node in fs.result) {
            if (best == null) {
                best = node;
            } else {
                var best_begin = new Position.from_libvala (best.source_reference.begin);
                var best_end = new Position.from_libvala (best.source_reference.end);
                var node_begin = new Position.from_libvala (node.source_reference.begin);
                var node_end = new Position.from_libvala (node.source_reference.end);

                if (best_begin.compare_to (node_begin) <= 0 && node_end.compare_to (best_end) <= 0 &&
                    !(best.source_reference.begin.column == node.source_reference.begin.column &&
                        node.source_reference.end.column == best.source_reference.end.column &&
                        // don't get implicit `this` accesses
                        ((node is Vala.MemberAccess && 
                         ((Vala.MemberAccess)node).member_name == "this" &&
                         ((Vala.MemberAccess)node).inner == null) ||
                        // fix for creation method quirks
                         (best is Vala.CreationMethod) ||
                        // fix for class/interface declaration quirks
                         (best is Vala.TypeSymbol) ||
                        // fix for variable declared in foreach
                         ((best is Vala.LocalVariable) && !(node is Vala.LocalVariable)))))
                    best = node;
            }
        }

        assert (best != null);
        // var sr = best.source_reference;
        // var from = (long)Util.get_string_pos (file.content, sr.begin.line-1, sr.begin.column-1);
        // var to = (long)Util.get_string_pos (file.content, sr.end.line-1, sr.end.column);
        // string contents = file.content [from:to];
        // debug ("Got best node: %s @ %s = %s", best.type_name, sr.to_string(), contents);

        return (!) best;
    }

    Vala.Scope get_current_scope (Vala.CodeNode code_node) {
        Vala.Scope? best = null;

        for (Vala.CodeNode? node = code_node; node != null; node = node.parent_node) {
            if (node is Vala.Symbol) {
                var sym = (Vala.Symbol) node;
                best = sym.scope;
                break;
            }
        }

        assert (best != null);

        return (!) best;
    }

    Vala.Scope get_topmost_scope (Vala.Scope topmost) {
        for (Vala.Scope? current_scope = topmost;
             current_scope != null;
             current_scope = current_scope.parent_scope)
            topmost = current_scope;

        return topmost;
    }

    /**
     * Gets the symbol you really want, not something from a generated file.
     *
     * If `sym` comes from a generated file (eg. a VAPI), then
     * it would be more useful to show the file specific to the compilation
     * that generated the file.
     */
    Vala.Symbol find_real_sym (Vala.Symbol sym) {
        Compilation alter_comp;
        
        if (sym.source_reference == null || sym.source_reference.file == null)
            return sym;

        if (project.lookup_compilation_for_output_file (sym.source_reference.file.filename, out alter_comp)) {
            Vala.Symbol? matching_sym;
            if (sym is Vala.Symbol) {
                if ((matching_sym = Util.find_matching_symbol (alter_comp.code_context, (Vala.Symbol)sym)) != null) {
                    return matching_sym;
                }
            }
        }
        return sym;
    }

    void textDocumentDefinition (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<LanguageServer.TextDocumentPositionParams> (@params);
        var results = project.lookup_compile_input_source_file (p.textDocument.uri);
        if (results.is_empty) {
            debug (@"[$method] file `$(p.textDocument.uri)' not found");
            reply_null (id, client, method);
            return;
        }

        wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }

            // ignore multiple results
            Vala.SourceFile file = results[0].first;
            Compilation compilation = results[0].second;

            Vala.CodeContext.push (compilation.code_context);
            var fs = new FindSymbol (file, p.position.to_libvala ());

            if (fs.result.size == 0) {
                try {
                    client.reply (id, new Variant.maybe (VariantType.VARIANT, null), cancellable);
                } catch (Error e) {
                    debug("[textDocument/definition] failed to reply to client: %s", e.message);
                }
                Vala.CodeContext.pop ();
                return;
            }

            Vala.CodeNode? best = get_best (fs, file);

            if (best is Vala.Expression && !(best is Vala.Literal)) {
                var b = (Vala.Expression)best;
                debug ("best (%p) is a Expression (symbol_reference = %p)", best, b.symbol_reference);
                if (b.symbol_reference != null && b.symbol_reference.source_reference != null) {
                    best = b.symbol_reference;
                    debug ("best is now the symbol_referenece => %p (%s)", best, best.to_string ());
                }
            } else if (best is Vala.DataType) {
                var dt = best as Vala.DataType;
                if (dt.type_symbol != null)
                    best = dt.type_symbol;
                else if (dt.symbol != null)
                    best = dt.symbol;
            } else {
                try {
                    client.reply (id, new Variant.maybe (VariantType.VARIANT, null), cancellable);
                } catch (Error e) {
                    debug("[textDocument/definition] failed to reply to client: %s", e.message);
                }
                Vala.CodeContext.pop ();
                return;
            }

            if (best is Vala.Symbol)
                best = find_real_sym ((Vala.Symbol) best);

            var location = new Location.from_sourceref (best.source_reference);
            debug ("[textDocument/definition] found location ... %s", location.uri);
            try {
                client.reply (id, Util.object_to_variant (location), cancellable);
            } catch (Error e) {
                debug("[textDocument/definition] failed to reply to client: %s", e.message);
            }
            Vala.CodeContext.pop ();
        });
    }

    void textDocumentDocumentSymbol (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<LanguageServer.TextDocumentPositionParams>(@params);
        var results = project.lookup_compile_input_source_file (p.textDocument.uri);
        if (results.is_empty) {
            debug (@"[$method] file `$(p.textDocument.uri)' not found");
            reply_null (id, client, method);
            return;
        }

        wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }

            // ignore multiple results
            Vala.SourceFile file = results[0].first;
            Compilation compilation = results[0].second;
            Vala.CodeContext.push (compilation.code_context);

            var array = new Json.Array ();
            var syms = new ListSymbols (file);
            if (init_params.capabilities.textDocument.documentSymbol.hierarchicalDocumentSymbolSupport)
                foreach (var dsym in syms) {
                    // debug(@"found $(dsym.name)");
                    array.add_element (Json.gobject_serialize (dsym));
                }
            else {
                foreach (var dsym in syms.flattened ()) {
                    // debug(@"found $(dsym.name)");
                    array.add_element (Json.gobject_serialize (new SymbolInformation.from_document_symbol (dsym, p.textDocument.uri)));
                }
            }

            try {
                Variant result = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (array), null);
                client.reply (id, result, cancellable);
            } catch (Error e) {
                debug (@"[textDocument/documentSymbol] failed to reply to client: $(e.message)");
            }
            Vala.CodeContext.pop ();
        });
    }

    public static Range get_best_range (Vala.Symbol sym) {
        var range = new Range.from_sourceref (sym.source_reference);

        if (sym is Vala.Method) {
            var m = (Vala.Method) sym;
            if (m.body != null && m.body.source_reference != null)
                range = range.union (get_best_range (m.body));
        }
        
        return range;
    }

    public static string get_expr_repr (Vala.Expression expr) {
        if (expr is Vala.Literal)
            return expr.to_string ();
        var sr = expr.source_reference;
        var file = sr.file;
        if (file.content == null)
            file.content = (string) file.get_mapped_contents ();
        var from = (long) Util.get_string_pos (file.content, sr.begin.line-1, sr.begin.column-1);
        var to = (long) Util.get_string_pos (file.content, sr.end.line-1, sr.end.column);
        return file.content [from:to];
    }

    public delegate bool FindFunc (Vala.CodeNode node);
    public static Vala.CodeNode? find_ancestor (Vala.CodeNode start_node, FindFunc filter) {
        for (Vala.CodeNode? current_node = start_node;
             current_node != null;
             current_node = current_node.parent_node)
            if (filter (current_node))
                return current_node;
        return null;
    }

    /**
     * Return the string representation of a symbol's type. This is used as the detailed
     * information for a completion item.
     */
    public static string? get_symbol_data_type (Vala.Symbol? sym, bool only_type_names = false, 
        Vala.Symbol? parent = null, bool show_inits = false, string? name_override = null) {
        if (sym == null) {
            return null;
        } else if (sym is Vala.Property) {
            var prop_sym = sym as Vala.Property;
            if (prop_sym.property_type == null)
                return null; 
            string weak_kw = (prop_sym.property_type.value_owned ||
                !(prop_sym.property_type is Vala.ReferenceType)) ? "" : "weak ";
            if (only_type_names)
                return @"$weak_kw$(prop_sym.property_type)";
            else {
                string? parent_str = get_symbol_data_type (parent, only_type_names);
                if (parent_str != null)
                    parent_str = @"$(parent_str)::";
                else
                    parent_str = "";
                return @"$weak_kw$(prop_sym.property_type) $parent_str$(prop_sym.name)";
            }
        } else if (sym is Vala.Callable) {
            var method_sym = sym as Vala.Callable;
            if (method_sym.return_type == null)
                return null;
            var creation_method = sym as Vala.CreationMethod;
            string? ret_type = method_sym.return_type.to_string ();
            string delg_type = (method_sym is Vala.Delegate) ? "delegate " : "";
            bool is_async = method_sym is Vala.Method && 
                ((Vala.Method)method_sym).coroutine && 
                !((Vala.Method)method_sym).get_async_begin_parameters ().is_empty;
            string param_string = "";
            bool at_least_one = false;
            var parameters = (is_async && name_override == "begin") ? 
                ((Vala.Method)method_sym).get_async_begin_parameters () : method_sym.get_parameters ();
            foreach (var p in parameters) {
                if (at_least_one)
                    param_string += ", ";
                param_string += get_symbol_data_type (p, only_type_names, null, show_inits);
                at_least_one = true;
            }
            string type_params = "";
            if (method_sym is Vala.Method) {
                var m = (Vala.Method) method_sym;
                at_least_one = false;
                foreach (var type_param in m.get_type_parameters ()) {
                    if (!at_least_one)
                        type_params += "<";
                    else
                        type_params += ",";
                    type_params += type_param.name;
                    at_least_one = true;
                }

                if (at_least_one)
                    type_params += ">";
            }
            string extern_kw = method_sym.is_extern ? "extern " : "";
            string async_type = is_async ? "async ": "";
            string signal_type = (method_sym is Vala.Signal) ? "signal " : "";
            string err_string = "";
            var error_types = new Vala.ArrayList<Vala.DataType> ();
            method_sym.get_error_types (error_types);
            if (!error_types.is_empty) {
                err_string = " throws ";
                at_least_one = false;
                foreach (var dt in error_types) {
                    if (at_least_one)
                        err_string += ", ";
                    err_string += get_symbol_data_type (dt.type_symbol, true);
                    at_least_one = true;
                }
            }
            string? parent_str = parent != null ? parent.to_string () : null;
            if (creation_method == null) {
                if (parent_str != null)
                    parent_str = @"$parent_str::";
                else
                    parent_str = "";
                return extern_kw + async_type + signal_type + delg_type + 
                    (ret_type ?? "void") + @" $parent_str$(name_override ?? sym.name)$type_params ($param_string)$err_string";
            } else {
                string sym_name = name_override ?? (sym.name == ".new" ? (parent_str ?? creation_method.class_name) : sym.name);
                string prefix_str = "";
                if (parent_str != null)
                    prefix_str = @"$parent_str::";
                else
                    prefix_str = @"$(creation_method.class_name)::";
                return @"$extern_kw$async_type$signal_type$delg_type$prefix_str$sym_name$type_params ($param_string)$err_string";
            }
        } else if (sym is Vala.Parameter) {
            var p = sym as Vala.Parameter;
            string param_string = "";
            if (p.ellipsis)
                param_string = "...";
            else {
                if (p.direction == Vala.ParameterDirection.OUT)
                    param_string = "out ";
                else if (p.direction == Vala.ParameterDirection.REF)
                    param_string = "ref ";
                if (only_type_names) {
                    if (p.variable_type.type_symbol != null)
                        param_string += p.variable_type.type_symbol.to_string ();
                } else {
                    param_string += p.variable_type.to_string ();
                    param_string += " " + p.name;
                    if (show_inits && p.initializer != null && p.initializer.source_reference != null)
                        param_string += @" = $(get_expr_repr (p.initializer))";
                }
            }
            return param_string;
        } else if (sym is Vala.Variable) {
            // Vala.Parameter is also a variable, so we've already
            // handled it as a special case
            var var_sym = sym as Vala.Variable;
            if (var_sym.variable_type == null)
                return null;
            string weak_kw = (var_sym.variable_type.value_owned ||
                    !(var_sym.variable_type is Vala.ReferenceType)) ? "" : "weak ";
            if (only_type_names)
                return @"$weak_kw$(var_sym.variable_type)";
            else {
                string? parent_str = get_symbol_data_type (parent, only_type_names);
                if (parent_str != null)
                    parent_str = @"$(parent_str)::";
                else
                    parent_str = "";
                string init_str = "";
                if (show_inits) {
                    var foreach_stmt = find_ancestor (var_sym, node => node is Vala.ForeachStatement) as Vala.ForeachStatement;
                    if (foreach_stmt != null && var_sym.name == foreach_stmt.variable_name) {
                        init_str = @" in $(foreach_stmt.collection)";
                    } else if (var_sym.initializer != null && var_sym.initializer.source_reference != null) {
                        init_str = @" = $(get_expr_repr (var_sym.initializer))";
                    }
                }
                return @"$weak_kw$(var_sym.variable_type) $parent_str$(var_sym.name)$init_str";
            }
        } else if (sym is Vala.EnumValue) {
            var ev_sym = sym as Vala.EnumValue;
            if (ev_sym.value != null) {
                if (only_type_names)
                    return ev_sym.value.to_string ();
                return @"$ev_sym = $(ev_sym.value)";
            }
            return ev_sym.to_string ();
        } else if (sym is Vala.Constant) {
            var const_sym = sym as Vala.Constant;
            string type_string = "";
            if (const_sym.value != null)
                type_string += const_sym.value.to_string ();
            if (const_sym.type_reference == null)
                return type_string;
            type_string = @"($(const_sym.type_reference)) $type_string";
            return type_string;
        } else if (sym is Vala.ObjectTypeSymbol) {
            var object_sym = sym as Vala.ObjectTypeSymbol;
            string type_string = object_sym.to_string ();
            bool at_least_one = false;

            foreach (var type_param in object_sym.get_type_parameters ()) {
                if (!at_least_one)
                    type_string += "<";
                else
                    type_string += ",";
                type_string += type_param.name;
                at_least_one = true;
            }

            if (at_least_one)
                type_string += ">";

            at_least_one = false;
            if (sym is Vala.Class) {
                var class_sym = sym as Vala.Class;
                at_least_one = false;
                foreach (var base_type in class_sym.get_base_types ()) {
                    if (!at_least_one)
                        type_string += ": ";
                    else
                        type_string += ", ";
                    type_string += base_type.to_string ();
                    at_least_one = true;
                }
            } else if (sym is Vala.Interface) {
                var iface_sym = sym as Vala.Interface;
                foreach (var prereq_type in iface_sym.get_prerequisites ()) {
                    if (!at_least_one)
                        type_string += ": ";
                    else
                        type_string += ", ";
                    type_string += prereq_type.to_string ();
                    at_least_one = true;
                }
            }
            if (object_sym is Vala.Class) {
                string abstract_kw = ((Vala.Class) object_sym).is_abstract ? "abstract " : "";
                return (only_type_names ? "" : @"$(abstract_kw)class ") + @"$type_string";
            } else
                return (only_type_names ? "" : "interface ") + @"$type_string";
        } else if (sym is Vala.ErrorCode) {
            var err_sym = sym as Vala.ErrorCode;
            if (err_sym.value != null) {
                if (only_type_names)
                    return err_sym.value.to_string ();
                return @"$err_sym = $(err_sym.value)";
            }
            return err_sym.to_string ();
        } else if (sym is Vala.Struct) {
            var struct_sym = sym as Vala.Struct;
            string extern_kw = struct_sym.is_extern ? "extern " : "";
            string type_string = struct_sym.to_string ();
            bool at_least_one = false;

            foreach (var type_param in struct_sym.get_type_parameters ()) {
                if (!at_least_one)
                    type_string += "<";
                else
                    type_string += ",";
                type_string += type_param.name;
                at_least_one = true;
            }

            if (at_least_one)
                type_string += ">";

            if (struct_sym.base_type != null)
                type_string += ": " + struct_sym.base_type.to_string ();

            return (only_type_names ? "" : @"$(extern_kw)struct ") + @"$type_string";
        } else if (sym is Vala.ErrorDomain) {
            // don't do this if LSP ever gets CompletionItemKind.Error
            var err_sym = sym as Vala.ErrorDomain;
            if (only_type_names)
                return err_sym.to_string ();
            return @"errordomain $err_sym";
        } else if (sym is Vala.Namespace) {
            var ns_sym = sym as Vala.Namespace;
            return @"$ns_sym";
        } else if (sym is Vala.Enum) {
            var enum_sym = sym as Vala.Enum;
            return (only_type_names ? "" : "enum ") + @"$(enum_sym.name)";
        } else if (sym is Vala.Destructor) {
            var dtor = sym as Vala.Destructor;
            string parent_str = parent != null ? parent.to_string () : 
                (dtor.this_parameter.variable_type.type_symbol.to_string ());
            string dtor_name = dtor.name ?? dtor.this_parameter.variable_type.type_symbol.name;
            return @"$parent_str::~$dtor_name ()";
        } else if (sym is Vala.TypeParameter) {
            return sym.name;
        } else {
            debug (@"get_symbol_data_type: unsupported symbol $(sym.type_name)");
        }
        return null;
    }

    public LanguageServer.MarkupContent? get_symbol_documentation (Vala.Symbol sym) {
        Vala.Symbol real_sym = find_real_sym (sym);
        sym = real_sym;
#if PARSE_SYSTEM_GIRS
        var gir_sym = documentation.find_gir_symbol (sym);
#endif
        string? comment = null;

        if (sym.comment != null) {
            comment = sym.comment.content;
            try {
                comment = /^\s*\*(.*)/m.replace (comment, comment.length, 0, "\\1");
            } catch (RegexError e) {
                warning (@"failed to parse comment...\n$comment\n...");
                comment = "(failed to parse comment)";
            }
#if PARSE_SYSTEM_GIRS
        } else if (gir_sym != null && gir_sym.comment != null) {
            comment = GirDocumentation.render_comment (gir_sym.comment);
#endif
        } else {
            return null;
        }

        return new MarkupContent () {
            kind = "markdown",
            value = comment
        };
    }

    /**
     * see `vala/valamemberaccess.vala`
     * This determines whether we can access a symbol in the current scope.
     */
    public static bool is_symbol_accessible (Vala.Symbol member, Vala.Scope current_scope) {
        if (member.access == Vala.SymbolAccessibility.PROTECTED && member.parent_symbol is Vala.TypeSymbol) {
            var target_type = (Vala.TypeSymbol) member.parent_symbol;
            bool in_subtype = false;

            for (Vala.Symbol? this_symbol = current_scope.owner; 
                 this_symbol != null;
                 this_symbol = this_symbol.parent_symbol) {
                if (this_symbol == target_type) {
                    in_subtype = true;
                    break;
                }

                var cl = this_symbol as Vala.Class;
                if (cl != null && cl.is_subtype_of (target_type)) {
                    in_subtype = true;
                    break;
                }
            }

            return in_subtype;
        } else if (member.access == Vala.SymbolAccessibility.PRIVATE) {
            var target_type = member.parent_symbol;
            bool in_target_type = false;

            for (Vala.Symbol? this_symbol = current_scope.owner;
                 this_symbol != null;
                 this_symbol = this_symbol.parent_symbol) {
                if (this_symbol == target_type) {
                    in_target_type = true;
                    break;
                }
            }

            return in_target_type;
        }
        return true;
    }

    /**
     * List all relevant members of a type. This is where completion options are generated.
     */
    void add_completions_for_type (Vala.TypeSymbol type, 
                                   Gee.Set<CompletionItem> completions, 
                                   Vala.Scope current_scope,
                                   bool is_instance,
                                   bool in_oce,
                                   Gee.Set<string> seen_props = new Gee.HashSet<string> ()) {
        if (type is Vala.ObjectTypeSymbol) {
            /**
             * Complete the members of this object, such as the fields,
             * properties, and methods.
             */
            var object_type = type as Vala.ObjectTypeSymbol;

            debug (@"completion: type is object $(object_type.name) (is_instance = $is_instance, in_oce = $in_oce)");

            foreach (var method_sym in object_type.get_methods ()) {
                if (method_sym.name == ".new") {
                    continue;
                } else if (is_instance && !in_oce) {
                    // for instance symbols, show only instance members
                    // except for creation methods, which are treated as instance members
                    if (!method_sym.is_instance_member () || method_sym is Vala.CreationMethod)
                        continue;
                } else if (in_oce) {
                    // only show creation methods for non-instance symbols within an OCE
                    if (!(method_sym is Vala.CreationMethod))
                        continue;
                } else {
                    // only show static methods for non-instance symbols
                    if (method_sym.is_instance_member ())
                        continue;
                }
                // check whether the symbol is accessible
                if (!is_symbol_accessible (method_sym, current_scope))
                    continue;
                completions.add (new CompletionItem.from_symbol (method_sym, (method_sym is Vala.CreationMethod) ? 
                    CompletionItemKind.Constructor : CompletionItemKind.Method, get_symbol_documentation (method_sym)));
            }

            if (!in_oce) {
                foreach (var field_sym in object_type.get_fields ()) {
                    if (field_sym.name[0] == '_' && seen_props.contains (field_sym.name[1:field_sym.name.length])
                        || field_sym.is_instance_member () != is_instance
                        || !is_symbol_accessible (field_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol (field_sym, CompletionItemKind.Field, get_symbol_documentation (field_sym)));
                }
            }

            if (!in_oce && is_instance) {
                foreach (var signal_sym in object_type.get_signals ()) {
                    if (signal_sym.is_instance_member () != is_instance 
                        || !is_symbol_accessible (signal_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol (signal_sym, CompletionItemKind.Event, get_symbol_documentation (signal_sym)));
                }

                foreach (var prop_sym in object_type.get_properties ()) {
                    if (prop_sym.is_instance_member () != is_instance
                        || !is_symbol_accessible (prop_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol (prop_sym, CompletionItemKind.Property, get_symbol_documentation (prop_sym)));
                    seen_props.add (prop_sym.name);
                }
            }

            // get inner types and constants
            if (!is_instance && !in_oce) {
                foreach (var constant_sym in object_type.get_constants ()) {
                    if (!is_symbol_accessible (constant_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol (constant_sym, CompletionItemKind.Constant, get_symbol_documentation (constant_sym)));
                }

                foreach (var enum_sym in object_type.get_enums ())
                    completions.add (new CompletionItem.from_symbol (enum_sym, CompletionItemKind.Enum, get_symbol_documentation (enum_sym)));

                foreach (var delegate_sym in object_type.get_delegates ())
                    completions.add (new CompletionItem.from_symbol (delegate_sym, CompletionItemKind.Interface, get_symbol_documentation (delegate_sym)));
            }

            // if we're inside an OCE (which are treated as instances), get only inner types
            if (!is_instance || in_oce) {
                foreach (var class_sym in object_type.get_classes ())
                    completions.add (new CompletionItem.from_symbol (class_sym, CompletionItemKind.Class, get_symbol_documentation (class_sym)));

                foreach (var iface_sym in object_type.get_interfaces ())
                    completions.add (new CompletionItem.from_symbol (iface_sym, CompletionItemKind.Interface, get_symbol_documentation (iface_sym)));

                foreach (var struct_sym in object_type.get_structs ())
                    completions.add (new CompletionItem.from_symbol (struct_sym, CompletionItemKind.Struct, get_symbol_documentation (struct_sym)));
            }

            // get instance members of supertypes
            if (is_instance && !in_oce) {
                if (object_type is Vala.Class) {
                    var class_sym = object_type as Vala.Class;
                    foreach (var base_type in class_sym.get_base_types ())
                        add_completions_for_type (base_type.type_symbol,
                                                  completions, current_scope, is_instance, in_oce, seen_props);
                }
                if (object_type is Vala.Interface) {
                    var iface_sym = object_type as Vala.Interface;
                    foreach (var base_type in iface_sym.get_prerequisites ())
                        add_completions_for_type (base_type.type_symbol,
                                                  completions, current_scope, is_instance, in_oce, seen_props);
                }
            }
        } else if (type is Vala.Enum) {
            /**
             * Complete members of this enum, such as the values, methods,
             * and constants.
             */
            var enum_type = type as Vala.Enum;

            foreach (var method_sym in enum_type.get_methods ()) {
                if (method_sym.is_instance_member () != is_instance
                    || !is_symbol_accessible (method_sym, current_scope))
                    continue;
                completions.add (new CompletionItem.from_symbol (method_sym, CompletionItemKind.Method, get_symbol_documentation (method_sym)));
            }

            if (!is_instance) {
                foreach (var constant_sym in enum_type.get_constants ()) {
                    if (!is_symbol_accessible (constant_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol (constant_sym, CompletionItemKind.Constant, get_symbol_documentation (constant_sym)));
                }
                foreach (var value_sym in enum_type.get_values ())
                    completions.add (new CompletionItem.from_symbol (value_sym, CompletionItemKind.EnumMember, get_symbol_documentation (value_sym)));
            }
        } else if (type is Vala.ErrorDomain) {
            /**
             * Get all the members of the error domain, such as the error
             * codes and the methods.
             */
            var errdomain_type = type as Vala.ErrorDomain;

            foreach (var code_sym in errdomain_type.get_codes ()) {
                if (code_sym.is_instance_member () != is_instance)
                    continue;
                completions.add (new CompletionItem.from_symbol (code_sym, CompletionItemKind.Value, get_symbol_documentation (code_sym)));
            }

            if (!in_oce) {
                foreach (var method_sym in errdomain_type.get_methods ()) {
                    if (method_sym.is_instance_member () != is_instance
                        || !is_symbol_accessible (method_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol (method_sym, CompletionItemKind.Method, get_symbol_documentation (method_sym)));
                }
            }

            if (is_instance && !in_oce) {
                Vala.Scope topmost = get_topmost_scope (current_scope);

                Vala.Symbol? gerror_sym = topmost.lookup ("GLib");
                if (gerror_sym != null) {
                    gerror_sym = gerror_sym.scope.lookup ("Error");
                    if (gerror_sym == null)
                        debug ("GLib.Error not found");
                    else
                        add_completions_for_type ((Vala.TypeSymbol) gerror_sym, completions, 
                            current_scope, is_instance, in_oce, seen_props);
                } else
                    debug ("GLib not found");
            }
        } else if (type is Vala.Struct) {
            /**
             * Gets all of the members of the struct.
             */
            var struct_type = type as Vala.Struct;

            foreach (var field_sym in struct_type.get_fields ()) {
                // struct fields are always public
                if (field_sym.is_instance_member () != is_instance)
                    continue;
                completions.add (new CompletionItem.from_symbol (field_sym, CompletionItemKind.Field, get_symbol_documentation (field_sym)));
            }

            foreach (var method_sym in struct_type.get_methods ()) {
                if (method_sym.is_instance_member () != is_instance
                    || !is_symbol_accessible (method_sym, current_scope))
                    continue;
                completions.add (new CompletionItem.from_symbol (method_sym, CompletionItemKind.Method, get_symbol_documentation (method_sym)));
            }

            foreach (var prop_sym in struct_type.get_properties ()) {
                if (prop_sym.is_instance_member () != is_instance
                    || !is_symbol_accessible (prop_sym, current_scope))
                    continue;
                completions.add (new CompletionItem.from_symbol (prop_sym, CompletionItemKind.Property, get_symbol_documentation (prop_sym)));
            }

            if (!is_instance) {
                foreach (var constant_sym in struct_type.get_constants ()) {
                    if (!is_symbol_accessible (constant_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol (constant_sym, CompletionItemKind.Constant, get_symbol_documentation (constant_sym)));
                }
            }
        } else {
            debug (@"other type node $(type).\n");
        }
    }

    /**
     * Use this when we're completing members of a namespace.
     */
    void add_completions_for_ns (Vala.Namespace ns, Gee.Set<CompletionItem> completions, bool in_oce) {
        foreach (var class_sym in ns.get_classes ())
            completions.add (new CompletionItem.from_symbol (class_sym, CompletionItemKind.Class, get_symbol_documentation (class_sym)));
        // this is outside of the OCE check because while we cannot create new instances of 
        // raw interfaces, it's possible for interfaces to contain instantiable types declared inside,
        // so that we would call `new Iface.Thing ()'
        foreach (var iface_sym in ns.get_interfaces ())
            completions.add (new CompletionItem.from_symbol (iface_sym, CompletionItemKind.Interface, get_symbol_documentation (iface_sym)));
        foreach (var struct_sym in ns.get_structs ())
            completions.add (new CompletionItem.from_symbol (struct_sym, CompletionItemKind.Struct, get_symbol_documentation (struct_sym)));
        foreach (var err_sym in ns.get_error_domains ())
            completions.add (new CompletionItem.from_symbol (err_sym, CompletionItemKind.Enum, get_symbol_documentation (err_sym)));
        foreach (var ns_sym in ns.get_namespaces ())
            completions.add (new CompletionItem.from_symbol (ns_sym, CompletionItemKind.Module, get_symbol_documentation (ns_sym)));
        if (!in_oce) {
            foreach (var const_sym in ns.get_constants ())
                completions.add (new CompletionItem.from_symbol (const_sym, CompletionItemKind.Constant, get_symbol_documentation (const_sym)));
            foreach (var method_sym in ns.get_methods ())
                completions.add (new CompletionItem.from_symbol (method_sym, CompletionItemKind.Method, get_symbol_documentation (method_sym)));
            foreach (var delg_sym in ns.get_delegates ())
                completions.add (new CompletionItem.from_symbol (delg_sym, CompletionItemKind.Interface, get_symbol_documentation (delg_sym)));
            foreach (var enum_sym in ns.get_enums ())
                completions.add (new CompletionItem.from_symbol (enum_sym, CompletionItemKind.Enum, get_symbol_documentation (enum_sym)));
        }
    }
    
    /**
     * Use this to complete members of a signal.
     */
    void add_completions_for_signal (Vala.Signal sig, Gee.Set<CompletionItem> completions) {
        var sig_type = new Vala.SignalType (sig);
        completions.add_all_array (new CompletionItem []{
            new CompletionItem.from_symbol (sig_type.get_member ("connect"), CompletionItemKind.Method, 
                new MarkupContent.plaintext ("Connect to signal")),
            new CompletionItem.from_symbol (sig_type.get_member ("connect_after"), CompletionItemKind.Method,
                new MarkupContent.plaintext ("Connect to signal after default handler")),
            new CompletionItem.from_symbol (sig_type.get_member ("disconnect"), CompletionItemKind.Method,
                new MarkupContent.plaintext ("Disconnect signal"))
        });
    }

    /**
     * Use this to complete members of an async method.
     */
    void add_completions_for_async_method (Vala.Method m, Gee.Set<CompletionItem> completions) {
        string param_string = "";
        bool at_least_one = false;
        foreach (var p in m.get_async_begin_parameters ()) {
            if (at_least_one)
                param_string += ", ";
            param_string += get_symbol_data_type (p, false, null, true);
            at_least_one = true;
        }
        completions.add_all_array(new CompletionItem []{
            new CompletionItem.from_symbol (m, CompletionItemKind.Method,
                new MarkupContent.plaintext ("Begin asynchronous operation"), "begin"),
            new CompletionItem.from_symbol (m.get_end_method (), CompletionItemKind.Method,
	    	new MarkupContent.plaintext ("Get results of asynchronous operation"))
        });
    }

    /**
     * Find the type of a symbol in the code.
     */
    Vala.TypeSymbol? get_type_symbol (Vala.CodeContext code_context, 
                                      Vala.CodeNode symbol, 
                                      bool is_pointer, 
                                      ref bool is_instance) {
        Vala.DataType? data_type = null;
        Vala.TypeSymbol? type_symbol = null;
        if (symbol is Vala.Variable) {
            var var_sym = symbol as Vala.Variable;
            data_type = var_sym.variable_type;
        } else if (symbol is Vala.Expression) {
            var expr = symbol as Vala.Expression;
            data_type = expr.value_type;
        }

        if (data_type != null) {
            do {
                if (data_type.type_symbol == null) {
                    if (data_type is Vala.ErrorType) {
                        var err_type = data_type as Vala.ErrorType;
                        if (err_type.error_code != null)
                            type_symbol = err_type.error_code;
                        else if (err_type.error_domain != null)
                            type_symbol = err_type.error_domain;
                        else {
                            // this is a generic error
                            Vala.Symbol? sym = code_context.root.scope.lookup ("GLib");
                            if (sym != null)
                                sym = sym.scope.lookup ("Error");
                            else
                                debug ("get_type_symbol(): GLib not found");
                            if (sym != null)
                                type_symbol = sym as Vala.TypeSymbol;
                            else
                                debug (@"could not get type symbol for $(data_type.type_name)");
                        }
                    } else if (data_type is Vala.PointerType && is_pointer) {
                        var ptype = data_type as Vala.PointerType;
                        data_type = ptype.base_type;
                        debug (@"peeled base_type $(data_type.type_name) from pointer type");
                        continue;       // try again
                    } else {
                        debug (@"could not get type symbol from $(data_type.type_name)");
                    }
                } else
                    type_symbol = data_type.type_symbol;
                break;
            } while (true);
        } else if (symbol is Vala.TypeSymbol) {
            type_symbol = symbol as Vala.TypeSymbol;
            is_instance = false;
        }

        return type_symbol;
    }

    void textDocumentCompletion (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<LanguageServer.CompletionParams>(@params);
        var results = project.lookup_compile_input_source_file (p.textDocument.uri);
        if (results.is_empty) {
            debug (@"[$method] failed to find file $(p.textDocument.uri)");
            reply_null (id, client, method);
            return;
        }
        Vala.SourceFile doc = results[0].first;
        Compilation compilation = results[0].second;
        bool is_pointer_access = false;
        long idx = (long) Util.get_string_pos (doc.content, p.position.line, p.position.character);

        Position pos = p.position.to_libvala ();
        Position end_pos = pos.dup ();
        bool is_member_access = false;

        // move back to the nearest member access if there is one
        long lb_idx = idx;

        // first, move back off the end of the current line
        if (doc.content[lb_idx] == '\n') {
            lb_idx--;
            if (doc.content[lb_idx] == '\r')    // TODO: is this really necessary?
                lb_idx--;
        }

        // now find a member access
        while (lb_idx >= 0 && !doc.content[lb_idx].isspace ()) {
            if (doc.content[lb_idx] == '.' || (lb_idx >= 1 && doc.content[lb_idx-1] == '-' && doc.content[lb_idx] == '>')) {
                var new_pos = pos.translate (0, (int) (lb_idx - idx));
                debug ("[%s] moved cursor back from %s -> %s", method, pos.to_string (), new_pos.to_string ());
                idx = lb_idx;
                pos = new_pos;
                end_pos = pos.dup ();
                break;
            } else if (!doc.content[lb_idx].isalnum() && doc.content[lb_idx] != '_') {
                // if this character does not belong to an identifier, break
                break;
            }
            lb_idx--;
        }
        
        if (idx >= 1 && doc.content[idx-1] == '-' && doc.content[idx] == '>') {
            is_pointer_access = true;
            is_member_access = true;
            debug (@"[$method] found pointer access @ $pos");
            pos = pos.translate (0, -2);
        } else if (doc.content[idx] == '.') {
            pos = pos.translate (0, -1);
            is_member_access = true;
        } else if (p.context != null) {
            if (p.context.triggerKind == CompletionTriggerKind.TriggerCharacter) {
                pos = pos.translate (0, -1);
                is_member_access = true;
            } else if (p.context.triggerKind == CompletionTriggerKind.Invoked)
                debug (@"[$method] invoked @ $pos");
            // TODO: incomplete completions
        }

        wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }

            debug (@"[$method] FindSymbol @ $(pos.to_libvala ())");
            Vala.CodeContext.push (compilation.code_context);

            var fs = new FindSymbol (doc, pos.to_libvala (), true, !is_member_access,
                 is_member_access ? end_pos.to_libvala () : null);

            if (fs.result.size == 0) {
                debug (@"[$method] no results found" + (is_member_access ? " for member access" : ""));
                reply_null (id, client, method);
                Vala.CodeContext.pop ();
                return;
            }


            bool in_oce = false;

            foreach (var res in fs.result) {
                debug (@"[$method] found $(res.type_name) (semanalyzed = $(res.checked))");
                in_oce |= res is Vala.ObjectCreationExpression;
            }
            
            var json_array = new Json.Array ();
            var completions = new Gee.HashSet<CompletionItem> ();

            if (!is_member_access) {
                var fs_results_saved = fs.result;
                fs.result = new Gee.ArrayList<Vala.CodeNode> ();

                // attempt to filter results
                foreach (var sym in fs_results_saved) 
                    if (sym is Vala.Block || sym is Vala.Symbol)
                        fs.result.add (sym);

                if (fs.result.is_empty)
                    fs.result = fs_results_saved;
                Vala.CodeNode best = get_best (fs, doc);
                Vala.Scope best_scope;
                bool in_instance = false;
                var seen_props = new Gee.HashSet<string> ();

                if (best is Vala.Block)
                    best_scope = ((Vala.Block) best).scope;
                else {
                    for (Vala.CodeNode? node = best; node != null; node = node.parent_node)
                        if (node is Vala.Symbol)
                            best_scope = ((Vala.Symbol) node).scope;
                    warning (@"[$method] invoke: could not get block from $best ($(best.type_name))");
                    reply_null (id, client, method);
                    Vala.CodeContext.pop ();
                    return;
                }

                debug (@"[$method] best scope SR is $(best_scope.owner.source_reference)");
                for (Vala.Scope? current_scope = best_scope;
                     current_scope != null;
                     current_scope = current_scope.parent_scope) {
                    Vala.Symbol owner = current_scope.owner;
                    if (owner is Vala.Callable || owner is Vala.Statement || owner is Vala.Block || 
                        owner is Vala.Subroutine) {
                        Vala.Symbol? this_param = null;
                        if (owner is Vala.Method)
                            this_param = ((Vala.Method)owner).this_parameter;
                        else if (owner is Vala.PropertyAccessor)
                            this_param = ((Vala.PropertyAccessor)owner).prop.this_parameter;
                        else if (owner is Vala.Constructor)
                            this_param = ((Vala.Constructor)owner).this_parameter;
                        else if (owner is Vala.Destructor)
                            this_param = ((Vala.Destructor)owner).this_parameter;
                        in_instance = this_param != null;
                        if (in_instance) {
                            // add `this' parameter
                            completions.add (new CompletionItem.from_symbol (this_param, CompletionItemKind.Constant, get_symbol_documentation (this_param)));
                        }
                        var symtab = current_scope.get_symbol_table ();
                        if (symtab == null)
                            continue;
                        foreach (Vala.Symbol sym in symtab.get_values ()) {
                            if (sym.name == null || sym.name[0] == '.')
                                continue;
                            var sr = sym.source_reference;
                            if (sr == null)
                                continue;
                            var sr_begin = new Position () { line = sr.begin.line, character = sr.begin.column - 1 };

                            // don't show local variables that are declared ahead of the cursor
                            if (sr_begin.compare_to (fs.pos) > 0)
                                continue;
                            completions.add (new CompletionItem.from_symbol (sym, 
                                (sym is Vala.Constant) ? CompletionItemKind.Constant : CompletionItemKind.Variable,
                                get_symbol_documentation (sym)));
                        }
                    } else if (owner is Vala.TypeSymbol) {
                        add_completions_for_type ((Vala.TypeSymbol) owner, completions, best_scope, in_instance, in_oce, seen_props);
                        // once we leave a type symbol, we're no longer in an instance
                        in_instance = false;
                    } else if (owner is Vala.Namespace) {
                        add_completions_for_ns ((Vala.Namespace) owner, completions, false);
                    } else {
                        debug (@"[$method] ignoring owner ($owner) ($(owner.type_name)) of scope");
                    }
                }
                // show members of all imported namespaces
                foreach (var ud in doc.current_using_directives)
                    add_completions_for_ns ((Vala.Namespace) ud.namespace_symbol, completions, in_oce);
            } else {
                Vala.CodeNode result = get_best (fs, doc);
                Vala.CodeNode? peeled = null;
                Vala.Scope current_scope = get_current_scope (result);

                debug (@"[$method] member: got $(result.type_name) `$result' (semanalyzed = $(result.checked)))");

                do {
                    if (result is Vala.MemberAccess) {
                        var ma = result as Vala.MemberAccess;
                        for (Vala.Expression? code_node = ma.inner; code_node != null; ) {
                            debug (@"[$method] MA inner: $code_node");
                            if (code_node is Vala.MemberAccess)
                                code_node = ((Vala.MemberAccess)code_node).inner;
                            else
                                code_node = null;
                        }
                        if (ma.symbol_reference != null) {
                            debug (@"peeling away symbol_reference from MemberAccess: $(ma.symbol_reference.type_name)");
                            peeled = ma.symbol_reference;
                        } else {
                            debug ("MemberAccess does not have symbol_reference");
                            if (!ma.checked) {
                                for (Vala.CodeNode? parent = ma.parent_node; 
                                    parent != null;
                                    parent = parent.parent_node)
                                {
                                    debug (@"parent ($parent) semanalyzed = $(parent.checked)");
                                }
                            }
                        }
                    }

                    bool is_instance = true;
                    Vala.TypeSymbol? type_sym = get_type_symbol (compilation.code_context, 
                                                                 result, is_pointer_access, ref is_instance);

                    // try again
                    if (type_sym == null && peeled != null)
                        type_sym = get_type_symbol (compilation.code_context,
                                                    peeled, is_pointer_access, ref is_instance);

                    if (type_sym != null)
                        add_completions_for_type (type_sym, completions, current_scope, is_instance, in_oce);
                    // and try some more
                    else if (peeled is Vala.Signal)
                        add_completions_for_signal ((Vala.Signal) peeled, completions);
                    else if (peeled is Vala.Namespace)
                        add_completions_for_ns ((Vala.Namespace) peeled, completions, in_oce);
                    else if (peeled is Vala.Method && ((Vala.Method) peeled).coroutine)
                        add_completions_for_async_method ((Vala.Method) peeled, completions);
                    else {
                        if (result is Vala.MemberAccess &&
                            ((Vala.MemberAccess)result).inner != null &&
                            // don't try inner if the outer expression already has a symbol reference
                            peeled == null) {
                            result = ((Vala.MemberAccess)result).inner;
                            debug (@"[$method] trying MemberAccess.inner");
                            // (new Object ()).
                            in_oce = false;
                            // maybe our expression was wrapped in extra parentheses:
                            // (x as T). for example
                            continue; 
                        }
                        if (result is Vala.ObjectCreationExpression &&
                            ((Vala.ObjectCreationExpression)result).member_name != null) {
                            result = ((Vala.ObjectCreationExpression)result).member_name;
                            debug (@"[$method] trying ObjectCreationExpression.member_name");
                            in_oce = true;
                            // maybe our object creation expression contains a member access
                            // from a namespace or some other type
                            // new Vls. for example
                            continue;
                        }
                        debug ("[%s] could not get datatype for %s", method,
                                result == null ? "(null)" : @"($(result.type_name)) $result");
                    }
                    break;      // break by default
                } while (true);
            }

            foreach (CompletionItem comp in completions)
                json_array.add_element (Json.gobject_serialize (comp));

            try {
                Variant variant_array = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (json_array), null);
                client.reply (id, variant_array, cancellable);
            } catch (Error e) {
                debug (@"[$method] failed to reply to client: $(e.message)");
            }

            Vala.CodeContext.pop ();
        });
    }

    void textDocumentSignatureHelp (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<LanguageServer.TextDocumentPositionParams>(@params);
        var results = project.lookup_compile_input_source_file (p.textDocument.uri);
        if (results.is_empty) {
            debug ("unknown file %s", p.textDocument.uri);
            reply_null (id, client, "textDocument/signatureHelp");
            return;
        }

        wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, "textDocument/signatureHelp");
                return;
            }

            Vala.SourceFile doc = results[0].first;
            Compilation compilation = results[0].second;
            Vala.CodeContext.push (compilation.code_context);

            var signatures = new Gee.ArrayList <SignatureInformation> ();
            var json_array = new Json.Array ();
            int active_param = 0;

            long idx = (long) Util.get_string_pos (doc.content, p.position.line, p.position.character);
            Position pos = p.position;

            if (idx >= 2 && doc.content[idx-1:idx] == "(") {
                debug ("[textDocument/signatureHelp] possible argument list");
                pos = p.position.translate (0, -2);
            } else if (idx >= 1 && doc.content[idx-1:idx] == ",") {
                debug ("[textDocument/signatureHelp] possible ith argument in list");
                pos = p.position.translate (0, -1);
            }

            var fs = new FindSymbol (doc, pos.to_libvala (), true);

            // filter the results for MethodCall's and ExpressionStatements
            var fs_results = fs.result;
            fs.result = new Gee.ArrayList<Vala.CodeNode> ();

            foreach (var res in fs_results) {
                debug (@"[textDocument/signatureHelp] found $(res.type_name) (semanalyzed = $(res.checked))");
                if (res is Vala.ExpressionStatement || res is Vala.MethodCall
                 || res is Vala.ObjectCreationExpression)
                    fs.result.add (res);
            }

            if (fs.result.size == 0 && fs_results.size > 0) {
                // In cases where our cursor is to the right of a method call and
                // not inside it (most likely because the right parenthesis is omitted),
                // we might not find any MethodCall or ExpressionStatements, so instead
                // look at whatever we found and see if it is a child of what we want.
                foreach (var res in fs_results) {
                    // walk up tree
                    for (Vala.CodeNode? x = res; x != null; x = x.parent_node)
                        if (x is Vala.ExpressionStatement || x is Vala.MethodCall)
                            fs.result.add (x);
                }
            }

            if (fs.result.size == 0) {
                debug ("[$method] no results found");
                reply_null (id, client, method);
                Vala.CodeContext.pop ();
                return;
            }

            Vala.CodeNode result = get_best (fs, doc);
            debug (@"[$method] got best: $(result.type_name) @ $(result.source_reference)");

            if (result is Vala.ExpressionStatement) {
                var estmt = result as Vala.ExpressionStatement;
                result = estmt.expression;
                debug (@"[$method] peeling away expression statement: $(result)");
            }

            var si = new SignatureInformation ();
            Vala.List<Vala.Parameter>? param_list = null;
            // The explicit symbol referenced, like a local variable
            // or a method. Could be null if we invoke an array element, 
            // for example.
            Vala.Symbol? explicit_sym = null;
            // The symbol referenced indirectly
            Vala.Symbol? type_sym = null;
            // The parent symbol (useful for creation methods)
            Vala.Symbol? parent_sym = null;
            // either "begin" or "end" or null
            string? coroutine_name = null;

            if (result is Vala.MethodCall) {
                var mc = result as Vala.MethodCall;
                var arg_list = mc.get_argument_list ();
                // TODO: NamedArgument's, whenever they become supported in upstream
#if VALA_FEATURE_INITIAL_ARGUMENT_COUNT
                active_param = mc.initial_argument_count - 1;
#endif
                if (active_param < 0)
                    active_param = 0;
                foreach (var arg in arg_list) {
                    debug (@"[$method] $mc: found argument ($arg)");
                }

                // get the method type from the expression
                Vala.DataType data_type = mc.call.value_type;
                explicit_sym = mc.call.symbol_reference;

                if (data_type is Vala.CallableType) {
                    var ct = data_type as Vala.CallableType;
                    param_list = ct.get_parameters ();
     
                    if (ct is Vala.DelegateType) {
                        var dt = ct as Vala.DelegateType;
                        type_sym = dt.delegate_symbol;
                    } else if (ct is Vala.MethodType) {
                        var mt = ct as Vala.MethodType;
                        type_sym = mt.method_symbol;

                        // handle special cases for .begin() and .end() in coroutines (async methods)
                        if (mc.call is Vala.MemberAccess && mt.method_symbol.coroutine &&
                            (explicit_sym == null || (((Vala.MemberAccess)mc.call).inner).symbol_reference == explicit_sym)) {
                            coroutine_name = ((Vala.MemberAccess)mc.call).member_name ?? "";
                            if (coroutine_name[0] == 'S')   // is possible because of incomplete member access
                                coroutine_name = null;
                            if (coroutine_name == "begin")
                                param_list = mt.method_symbol.get_async_begin_parameters ();
                            else if (coroutine_name == "end") {
                                param_list = mt.method_symbol.get_async_end_parameters ();
                                type_sym = mt.method_symbol.get_end_method ();
                                coroutine_name = null;  // .end() is its own method
                            } else if (coroutine_name != null) {
                                debug (@"[$method] coroutine name `$coroutine_name' not handled");
                            }
                        }
                    } else if (ct is Vala.SignalType) {
                        var st = ct as Vala.SignalType;
                        type_sym = st.signal_symbol;
                    }
                }
            } else if (result is Vala.ObjectCreationExpression
#if VALA_FEATURE_INITIAL_ARGUMENT_COUNT
                        && ((Vala.ObjectCreationExpression)result).initial_argument_count != -1
#endif
			) {
                var oce = result as Vala.ObjectCreationExpression;
                var arg_list = oce.get_argument_list ();
                // TODO: NamedArgument's, whenever they become supported in upstream
#if VALA_FEATURE_INITIAL_ARGUMENT_COUNT
                active_param = oce.initial_argument_count - 1;
#endif
                if (active_param < 0)
                    active_param = 0;
                foreach (var arg in arg_list) {
                    debug (@"$oce: found argument ($arg)");
                }

                explicit_sym = oce.symbol_reference;

                if (explicit_sym == null && oce.member_name != null) {
                    explicit_sym = oce.member_name.symbol_reference;
                    debug (@"[textDocument/signatureHelp] explicit_sym = $explicit_sym $(explicit_sym.type_name)");
                }

                if (explicit_sym != null && explicit_sym is Vala.Callable) {
                    var callable_sym = explicit_sym as Vala.Callable;
                    param_list = callable_sym.get_parameters ();
                }

                parent_sym = explicit_sym.parent_symbol;
            } else {
                debug (@"[$method] neither a method call nor (complete) object creation expr");
                reply_null (id, client, method);
                Vala.CodeContext.pop ();
                return;     // early exit
            } 

            if (explicit_sym == null && type_sym == null) {
                debug (@"[$method] could not get explicit_sym and type_sym from $(result.type_name)");
                reply_null (id, client, method);
                Vala.CodeContext.pop ();
                return;
            }

            if (explicit_sym == null) {
                si.label = get_symbol_data_type (type_sym, false, null, true);
                si.documentation = get_symbol_documentation (type_sym);
            } else {
                // TODO: need a function to display symbol names correctly given context
                if (type_sym != null) {
                    si.label = get_symbol_data_type (type_sym, false, null, true, coroutine_name);
                    si.documentation = get_symbol_documentation (type_sym);
                } else {
                    si.label = get_symbol_data_type (explicit_sym, false, parent_sym, true, coroutine_name);
                }
                // try getting the documentation for the explicit symbol
                // if the type does not have any documentation
                if (si.documentation == null)
                    si.documentation = get_symbol_documentation (explicit_sym);
            }

            if (param_list != null) {
                foreach (var parameter in param_list) {
                    si.parameters.add (new ParameterInformation () {
                        label = get_symbol_data_type (parameter, false, null, true),
                        documentation = get_symbol_documentation (parameter)
                    });
                    debug (@"found parameter $parameter (name = $(parameter.ellipsis ? "..." :parameter.name))");
                }
                signatures.add (si);
            }


            foreach (var sinfo in signatures)
                json_array.add_element (Json.gobject_serialize (sinfo));

            try {
                Variant variant_array = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (json_array), null);
                client.reply (id, buildDict (
                    signatures: variant_array,
                    activeParameter: new Variant.int32 (active_param)
                ), cancellable);
            } catch (Error e) {
                debug (@"[textDocument/signatureHelp] failed to reply to client: $(e.message)");
            }

            Vala.CodeContext.pop ();
        });
    }

    void textDocumentHover (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<LanguageServer.TextDocumentPositionParams>(@params);
        var results = project.lookup_compile_input_source_file (p.textDocument.uri);
        if (results.is_empty) {
            debug (@"file `$(p.textDocument.uri)' not found");
            reply_null (id, client, "textDocument/hover");
            return;
        }

        Position pos = p.position;
        wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, "textDocument/hover");
                return;
            }

            Vala.SourceFile doc = results[0].first;
            Compilation compilation = results[0].second;
            Vala.CodeContext.push (compilation.code_context);

            var fs = new FindSymbol (doc, pos.to_libvala (), true);

            if (fs.result.size == 0) {
                debug ("[textDocument/hover] no results found");
                reply_null (id, client, "textDocument/hover");
                Vala.CodeContext.pop ();
                return;
            }

            Vala.CodeNode result = get_best (fs, doc);
            if (result is Vala.Symbol) {
                Vala.Symbol real_sym = find_real_sym ((Vala.Symbol)result);
                result = real_sym;
            }
            var hoverInfo = new Hover () {
                range = new Range.from_sourceref (result.source_reference)
            };

            if (result is Vala.DataType) {
                var dt = result as Vala.DataType;
                if (dt.type_symbol != null)
                    result = dt.type_symbol;
                else if (dt.symbol != null)
                    result = dt.symbol;
            }

            do {
                if (result is Vala.Symbol) {
                    var sym = (Vala.Symbol) result;
                    if (sym.name != null && sym.name.length > 0 && sym.name[0] == '.') {
                        if (sym is Vala.Variable && ((Vala.Variable)sym).initializer != null) {
                            result = ((Vala.Variable)sym).initializer;
                            continue;   // try again
                        }
                        debug (@"[$method] could not handle temp variable");
                    }
                    hoverInfo.contents.add (new MarkedString () {
                        language = "vala",
                        value = get_symbol_data_type (result as Vala.Symbol, false, null, true)
                    });
                    var comment = get_symbol_documentation (result as Vala.Symbol);
                    if (comment != null) {
                        hoverInfo.contents.add (new MarkedString () {
                            value = comment.value
                        });
                    }
                } else if (result is Vala.Expression && ((Vala.Expression)result).symbol_reference != null) {
                    var expr = result as Vala.Expression;
                    var sym = expr.symbol_reference;
                    bool is_temp_expr = sym.name.length > 0 && sym.name[0] == '.';
                    hoverInfo.contents.add (new MarkedString () {
                        language = "vala",
                        value = get_symbol_data_type (sym, 
                            result is Vala.Literal || (is_temp_expr && !(sym is Vala.Callable)), null, true)
                    });
                    var comment = get_symbol_documentation (sym);
                    if (comment != null) {
                        hoverInfo.contents.add (new MarkedString () {
                            value = comment.value
                        });
                    }
                } else if (result is Vala.CastExpression) {
                    hoverInfo.contents.add (new MarkedString () {
                        language = "vala",
                        value = get_expr_repr ((Vala.CastExpression) result)
                    });
                } else {
                    bool is_instance = true;
                    Vala.TypeSymbol? type_sym = get_type_symbol (compilation.code_context,
                                                                 result, false, ref is_instance);
                    hoverInfo.contents.add (new MarkedString () {
                        language = "vala",
                        value = type_sym != null ? get_symbol_data_type (type_sym, true, null, true) : 
                            ((result is Vala.Expression) ? get_expr_repr ((Vala.Expression) result) : result.to_string ())
                    });
                }
                break;
            } while (true);

            debug (@"[textDocument/hover] got $result $(result.type_name)");

            try {
                client.reply (id, Util.object_to_variant (hoverInfo), cancellable);
            } catch (Error e) {
                debug ("[textDocument/hover] failed to reply to client: %s", e.message);
            }

            Vala.CodeContext.pop ();
        });
    }

    DocumentHighlightKind determine_node_highlight_kind (Vala.CodeNode node) {
        Vala.CodeNode? previous_node = node;

        for (Vala.CodeNode? current_node = node.parent_node;
             current_node != null;
             current_node = current_node.parent_node,
             previous_node = current_node) {
            if (current_node is Vala.MethodCall)
                return DocumentHighlightKind.Read;
            else if (current_node is Vala.Assignment) {
                if (previous_node == ((Vala.Assignment)current_node).left)
                    return DocumentHighlightKind.Write;
                else if (previous_node == ((Vala.Assignment)current_node).right)
                    return DocumentHighlightKind.Read;
            } else if (current_node is Vala.DeclarationStatement &&
                node == ((Vala.DeclarationStatement)current_node).declaration)
                return DocumentHighlightKind.Write;
            else if (current_node is Vala.ForeachStatement &&
                node == ((Vala.ForeachStatement)current_node).element_variable)
                return DocumentHighlightKind.Write;
            else if (current_node is Vala.Statement)
                return DocumentHighlightKind.Read;
        }

        return DocumentHighlightKind.Text;
    }

    void textDocumentReferences (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<LanguageServer.TextDocumentPositionParams>(@params);
        var results = project.lookup_compile_input_source_file (p.textDocument.uri);
        if (results.is_empty) {
            debug (@"file `$(p.textDocument.uri)' not found");
            reply_null (id, client, method);
            return;
        }

        Position pos = p.position;
        bool is_highlight = method == "textDocument/documentHighlight";
        wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }

            Vala.SourceFile doc = results[0].first;
            Compilation compilation = results[0].second;
            Vala.CodeContext.push (compilation.code_context);

            var fs = new FindSymbol (doc, pos.to_libvala (), true);

            if (fs.result.size == 0) {
                debug (@"[$method] no results found");
                reply_null (id, client, method);
                Vala.CodeContext.pop ();
                return;
            }

            Vala.CodeNode result = get_best (fs, doc);
            var json_array = new Json.Array ();
            var references = new Gee.ArrayList<Vala.CodeNode> ();

            if (result is Vala.Expression && ((Vala.Expression)result).symbol_reference != null)
                result = ((Vala.Expression) result).symbol_reference;
            else if (result is Vala.DataType && ((Vala.DataType)result).type_symbol != null)
                result = ((Vala.DataType) result).type_symbol;

            debug (@"[$method] got best: $result ($(result.type_name))");
            // show references in all files
            foreach (var file in compilation.get_project_files ()) {
                if (result is Vala.TypeSymbol) {
                    var fs2 = new FindSymbol.with_filter (file, result,
                        (needle, node) => node == needle ||
                            (node is Vala.DataType && ((Vala.DataType) node).type_symbol == needle));
                    references.add_all (fs2.result);
                }
                if (result is Vala.Symbol) {
                    var fs2 = new FindSymbol.with_filter (file, result, 
                        (needle, node) => node == needle || 
                            (node is Vala.Expression && ((Vala.Expression)node).symbol_reference == needle));
                    references.add_all (fs2.result);
                }
            }
            
            debug (@"[$method] found $(references.size) reference(s)");
            foreach (var node in references) {
                if (is_highlight) {
                    json_array.add_element (Json.gobject_serialize (new DocumentHighlight () {
                        range = new Range.from_sourceref (node.source_reference),
                        kind = determine_node_highlight_kind (node)
                    }));
                } else {
                    json_array.add_element (Json.gobject_serialize (new Location.from_sourceref (node.source_reference)));
                }
            }

            try {
                Variant variant_array = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (json_array), null);
                client.reply (id, variant_array, cancellable);
            } catch (Error e) {
                debug (@"[$method] failed to reply to client: $(e.message)");
            }

            Vala.CodeContext.pop ();
        });
    }

    void textDocumentImplementation (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<LanguageServer.TextDocumentPositionParams>(@params);
        var results = project.lookup_compile_input_source_file (p.textDocument.uri);
        if (results.is_empty) {
            debug (@"file `$(p.textDocument.uri)' not found");
            reply_null (id, client, method);
            return;
        }

        Position pos = p.position;
        wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }

            Vala.SourceFile doc = results[0].first;
            Compilation compilation = results[0].second;
            Vala.CodeContext.push (compilation.code_context);

            var fs = new FindSymbol (doc, pos.to_libvala (), true);

            if (fs.result.size == 0) {
                debug (@"[$method] no results found");
                reply_null (id, client, method);
                Vala.CodeContext.pop ();
                return;
            }

            Vala.CodeNode result = get_best (fs, doc);
            var json_array = new Json.Array ();
            var references = new Gee.ArrayList<Vala.CodeNode> ();

            if (result is Vala.DataType && ((Vala.DataType)result).type_symbol != null)
                result = ((Vala.DataType) result).type_symbol;

            debug (@"[$method] got best: $result ($(result.type_name))");
            bool is_abstract_type = (result is Vala.Interface) || ((result is Vala.Class) && ((Vala.Class)result).is_abstract);
            bool is_abstract_or_virtual_method = (result is Vala.Method) && 
                (((Vala.Method)result).is_abstract || ((Vala.Method)result).is_virtual);
            bool is_abstract_or_virtual_property = (result is Vala.Property) &&
                (((Vala.Property)result).is_abstract || ((Vala.Property)result).is_virtual);

            if (!is_abstract_type && !is_abstract_or_virtual_method && !is_abstract_or_virtual_property) {
                debug (@"[$method] best is neither an abstract type/interface nor abstract/virtual method/property");
                reply_null (id, client, method);
                Vala.CodeContext.pop ();
                return;
            }

            // show references in all files
            foreach (var file in compilation.get_project_files ()) {
                FindSymbol fs2;
                if (is_abstract_type) {
                    fs2 = new FindSymbol.with_filter (file, result,
                    (needle, node) => {
                        if (node is Vala.Class) {
                            foreach (Vala.DataType dt in ((Vala.Class) node).get_base_types ())
                                if (dt.type_symbol == needle)
                                    return true;
                        } else if (node is Vala.Interface) {
                            foreach (Vala.DataType dt in ((Vala.Interface) node).get_prerequisites ())
                                if (dt.type_symbol == needle)
                                    return true;
                        }
                        return false;
                    });
                } else if (is_abstract_or_virtual_method) {
                    fs2 = new FindSymbol.with_filter (file, result,
                    (needle, node) => needle != node && (node is Vala.Method) && 
                        (((Vala.Method)node).base_method == needle ||
                         ((Vala.Method)node).base_interface_method == needle));
                } else {
                    fs2 = new FindSymbol.with_filter (file, result,
                    (needle, node) => needle != node && (node is Vala.Property) &&
                        (((Vala.Property)node).base_property == needle ||
                         ((Vala.Property)node).base_interface_property == needle));
                }
                references.add_all (fs2.result);
            }

            debug (@"[$method] found $(references.size) reference(s)");
            foreach (var node in references) {
                Vala.CodeNode real_node = node;
                if (node is Vala.Symbol)
                    real_node = find_real_sym ((Vala.Symbol) node);
                json_array.add_element (Json.gobject_serialize (new Location.from_sourceref (real_node.source_reference)));
            }

            try {
                Variant variant_array = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (json_array), null);
                client.reply (id, variant_array, cancellable);
            } catch (Error e) {
                debug (@"[$method] failed to reply to client: $(e.message)");
            }

            Vala.CodeContext.pop ();
        });
    }

    // TODO: avoid recreating SymbolInformation unless the compilation has changed?
    void workspaceSymbol (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var query = (string) @params.lookup_value ("query", VariantType.STRING);

        wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }

            var json_array = new Json.Array ();
            foreach (var text_document in project.get_project_source_files ()) {
                Vala.CodeContext.push (text_document.context);
                new ListSymbols (text_document)
                    .flattened ()
                    // NOTE: if introspection for g_str_match_string () / string.match_string ()
                    // is fixed, this will have to be changed to `dsym.name.match_sting (query, true)`
                    .filter (dsym => query.match_string (dsym.name, true))
                    .foreach (dsym => {
                        var si = new SymbolInformation.from_document_symbol (dsym, File.new_for_path (text_document.filename).get_uri ());
                        json_array.add_element (Json.gobject_serialize (si));
                        return true;
                    });
                Vala.CodeContext.pop ();
            }

            debug (@"[$method] found $(json_array.get_length ()) element(s) matching `$query'");
            try {
                Variant variant_array = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (json_array), null);
                client.reply (id, variant_array, cancellable);
            } catch (Error e) {
                debug (@"[$method] failed to reply to client: $(e.message)");
            }
        });
    }

    void shutdown (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        reply_null (id, client, "shutdown");
        shutdown_real ();
    }

    void exit (Jsonrpc.Client client, Variant @params) {
        shutdown_real ();
    }

    void shutdown_real () {
        debug ("shutting down...");
        this.shutting_down = true;
        cancellable.cancel ();
        if (event != 0)
            server.disconnect (event);
        loop.quit ();
        foreach (uint id in g_sources)
            Source.remove (id);
    }
}

void main () {
    var loop = new MainLoop ();
    new Vls.Server (loop);
    loop.run ();
}
