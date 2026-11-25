; Provider layer + tool parsing tests.
; OpenAI-compatible path is tested over REAL HTTP against tests/fake_openai.py.

!(import! &self ../core/agent)
!(import! &self "fake_openai.py")
!(import! &self "fake_tools.py")
!(set-config retry-backoff 0)
!(set-config llm-backoff 0)
!(set-config brain llm)                       ; real client, not the scripted brain

; ---------------- provider selection ----------------
!(py-call (fake_openai.unset_env "GEMINI_API_KEY"))
!(py-call (fake_openai.unset_env "OPENAI_API_KEY"))
!(py-call (fake_openai.unset_env "OPENAI_BASE_URL"))
!(py-call (fake_openai.unset_env "PAGENT_PROVIDER"))
!(test (py-call (llm_client.provider)) gemini)          ; nothing set → gemini (+ clear error)
!(test (index-atom (ask-llm "s" "p") 1) config)
!(py-call (fake_openai.set_env "OPENAI_API_KEY" "x"))
!(test (py-call (llm_client.provider)) openai)          ; OpenAI key → openai
!(py-call (fake_openai.set_env "PAGENT_PROVIDER" "gemini"))
!(test (py-call (llm_client.provider)) gemini)          ; explicit choice wins
!(py-call (fake_openai.set_env "PAGENT_PROVIDER" "openai"))

; ---------------- OpenAI-compatible over HTTP ----------------
!(py-call (fake_openai.start))
!(py-call (fake_openai.set_env "OPENAI_API_KEY" "test-key"))
!(py-call (fake_openai.unset_env "OPENAI_MODEL"))
!(test (index-atom (ask-llm "s" "p") 1) config)         ; model must be named, no guessing
!(py-call (fake_openai.set_env "OPENAI_MODEL" "fake-model"))
!(test (repr (ask-llm "SYSTEM RULES" "user data")) "(ok (final \"hi\"))")
; our instructions go in the system message, data in the user message
!(test (py-call (fake_openai.last_request_roles)) (system user))
!(test (py-call (fake_openai.last_system_has "SYSTEM RULES")) True)

; error classification (same kinds as Gemini, so recovery works unchanged)
!(py-call (fake_openai.set_env "OPENAI_API_KEY" "wrong"))
!(test (index-atom (ask-llm "s" "p") 1) auth)
!(test (temporary-error auth) False)
!(py-call (fake_openai.set_env "OPENAI_API_KEY" "test-key"))
!(py-call (fake_openai.set_env "OPENAI_MODEL" "missing-model"))
!(test (index-atom (ask-llm "s" "p") 1) model-not-found)
!(py-call (fake_openai.set_env "OPENAI_MODEL" "rate"))
!(test (index-atom (ask-llm "s" "p") 1) rate-limit)
!(test (temporary-error rate-limit) True)
!(py-call (fake_openai.set_env "OPENAI_MODEL" "broken"))
!(test (index-atom (ask-llm "s" "p") 1) server)
; the key never appears in error messages
!(py-call (fake_openai.set_env "OPENAI_API_KEY" "sk-secret-abc-123"))
!(test (py-call (operator.contains (repr (ask-llm "s" "p")) "sk-secret-abc-123")) False)
!(py-call (fake_openai.set_env "OPENAI_API_KEY" "test-key"))

; local servers (Ollama, LM Studio...) don't need a key
!(py-call (fake_openai.unset_env "OPENAI_API_KEY"))
!(py-call (fake_openai.set_env "OPENAI_MODEL" "fake-model"))
!(test (index-atom (ask-llm "s" "p") 1) auth)          ; reached the server (it wants a key)
!(py-call (fake_openai.set_env "OPENAI_API_KEY" "test-key"))

; nothing listening → network (temporary)
!(let $saved (py-call (os.getenv "OPENAI_BASE_URL"))
      (let* (($a (py-call (fake_openai.set_env "OPENAI_BASE_URL" "http://127.0.0.1:9/v1")))
             ($r (ask-llm "s" "p"))
             ($b (py-call (fake_openai.set_env "OPENAI_BASE_URL" $saved))))
            (test (index-atom $r 1) network)))

; an EMPTY reply (thinking models) is asked again once ...
!(py-call (fake_openai.queue_replies ("" "(final \"second try\")")))
!(test (repr (ask-llm "s" "p")) "(ok (final \"second try\"))")
; ... and if it stays empty it is an invalid reply for the agent, never a fatal stop
!(py-call (fake_openai.queue_replies ("" "")))
!(test (let (ok $t) (ask-llm "s" "p") (parse-reply $t)) (invalid no-expression))

; native tool_calls are understood
!(py-call (fake_openai.set_env "OPENAI_MODEL" "tool-caller"))
!(declare-tool calc "arithmetic" safe fake_tools.upper)
!(test (let (ok $t) (ask-llm "s" "p") (parse-reply $t)) (action calc "2+3"))
!(py-call (fake_openai.set_env "OPENAI_MODEL" "fake-model"))

; ---------------- tool parsing: JSON replies → the same atoms ----------------
!(test (parse-reply "{\"tool\": \"calc\", \"input\": \"2+3\"}") (action calc "2+3"))
!(test (parse-reply "```json\n{\"action\": \"web_search\", \"arguments\": {\"query\": \"rust\"}}\n```")
       (action web-search "rust"))
!(test (parse-reply "{\"final\": \"42\"}") (final "42"))
!(test (parse-reply "{\"answer\": \"Paris\"}") (final "Paris"))
!(test (parse-reply "{\"task_done\": \"t1\"}") (task-done t1))
!(test (parse-reply "{\"ask_user\": \"which file?\"}") (ask-user "which file?"))
!(test (parse-reply "Sure! {\"tool\": \"calc\", \"input\": \"say \\\"hi\\\"\"}") (action calc "say \"hi\""))
!(test (parse-reply "{\"plan\": [{\"id\": \"t1\", \"task\": \"look up\", \"uses\": \"research\"}, {\"id\": \"t2\", \"task\": \"add\", \"after\": [\"t1\"]}]}")
       (plan (task t1 "look up" (uses research)) (task t2 "add" (after t1))))
!(test (parse-reply "{\"verdict\": \"unsupported\", \"reason\": \"no evidence\"}") (verdict unsupported "no evidence"))
; S-expressions still win when both appear
!(test (parse-reply "(final \"sexpr\") {\"final\": \"json\"}") (final "sexpr"))
!(test (parse-reply "{\"nonsense\": 1}") (invalid no-expression))
; JSON-proposed tools go through the same path: an unknown tool reaches (execute ..), which refuses it
!(test (check-proposal (parse-reply "{\"tool\": \"rm_rf\", \"input\": \"/\"}")) (action rm-rf "/"))
!(test (car-atom (index-atom (execute rm-rf "/") 1)) unknown-tool)
; OpenAI-style {"tool_calls": [...]} with several calls → one (actions ..)
!(test (parse-reply "{\"tool_calls\": [{\"tool\": \"calc\", \"input\": \"1\"}, {\"tool\": \"calc\", \"input\": \"2\"}]}")
       (actions (action calc "1") (action calc "2")))
; input as an object with extras (gpt-oss): the command is taken, the extras dropped,
; and a command list keeps its quoting (bash -lc 'python3 -m unittest')
!(test (parse-reply "{\"tool\": \"run-shell\", \"input\": {\"cmd\": [\"bash\", \"-lc\", \"python3 -m unittest\"], \"timeout\": 60000}}")
       (action run-shell "bash -lc 'python3 -m unittest'"))
!(test (parse-reply "{\"tool\": \"read-file\", \"input\": {\"path\": \"a.md\", \"encoding\": \"utf-8\"}}") (action read-file "a.md"))
; write-file's own JSON stays whole
!(test (parse-reply "{\"tool\": \"write-file\", \"input\": {\"path\": \"a.md\", \"content\": \"hi\"}}")
       (action write-file "{\"path\": \"a.md\", \"content\": \"hi\"}"))
; the input given next to the tool name, without an "input" key
!(test (parse-reply "{\"tool\": \"run-shell\", \"cmd\": [\"ls\", \"-la\"]}") (action run-shell "ls -la"))
; a harness namespace in front of the tool name is dropped; an empty object is no input
!(test (parse-reply "{\"name\": \"repo_browser.list_files\", \"arguments\": {}}") (action list-files ""))
!(test (parse-reply "{\"tool\": \"functions.calc\", \"input\": \"1+1\"}") (action calc "1+1"))

; ---------------- a whole agent run over HTTP, mixing JSON and S-expressions ----------------
!(py-call (fake_openai.queue_replies
            ("{\"plan\": [{\"id\": \"t1\", \"task\": \"shout\"}]}"
             "{\"tool\": \"calc\", \"input\": \"hello\"}"
             "(task-done t1)"
             "{\"final\": \"HELLO\"}"
             "(verdict supported \"matches the observation\")")))
!(test (run-agent "shout hello") (done "HELLO"))
!(test (match &wm (step 1 calc $i $o) $o) (ok HELLO))
!(test (match &wm (verification 1 semantic $r) $r) pass)
