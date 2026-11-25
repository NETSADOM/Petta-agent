; The agent's required tools — read file, write file, run a shell command,
; send a message, ask the user — and the rule they all share:
;   every tool returns text; errors, missing files and timeouts come back as
;   (error "why") the agent can read, and never crash it.
; stdin (run_tests.sh), in order:
;   1. "y"         approve a destructive run-shell (rm); read-only ones never ask
;   2. "  green  " answer to ask-user (trimmed)
;   3. ""          an empty answer
;   4. "teal"      ask-user answer      (end-to-end scenario; its new file needs no approval)
;   then EOF       → the run-shell rm approval is refused, ask-user reports closed input

!(import! &self "fake_openai.py")
!(py-call (fake_openai.set_env "PAGENT_WORKSPACE" "data/test_tools_ws"))
!(py-call (fake_openai.set_env "PAGENT_TEST_API_KEY" "should-not-leak"))
!(import! &self ../core/agent)
!(import! &self ../my_capabilities)
!(import! &self "fake_tools.py")
!(set-config retry-backoff 0)
!(py-call (fake_tools.make_fixtures (py-call (agent_tools.workspace))))

; ---------------- all five are declared ----------------
!(test (collapse (let $t (superpose (read-file write-file run-shell send-message ask-user))
                      (if (tool-known $t) (empty) (missing $t))))
       ())
!(test (needs-approval run-shell) True)
!(test (needs-approval write-file) True)
!(test (allowed send-message) True)
!(test (allowed ask-user) True)

; ---------------- read-file: every failure is a sentence ----------------
!(test (repr (execute read-file "nope.txt")) "(error no such file: nope.txt (use list-files))")
!(test (repr (execute read-file "folder")) "(error folder is a directory, not a file (use list-files))")
!(test (py-call (fake_tools.has (repr (execute read-file "blob.bin")) "binary file")) True)
!(test (repr (execute read-file "empty.txt")) "(ok (the file empty.txt is empty))")
!(test (repr (execute read-file "../../README.md")) "(error path leaves the workspace)")
!(test (car-atom (index-atom (execute read-file "") 1)) invalid-input)

; ---------------- write-file (called directly; approval is tested below) ----------------
!(test (car-atom (py-call (agent_tools.write_file "{not json"))) error)
!(test (py-call (fake_tools.has (repr (py-call (agent_tools.write_file "[1, 2]"))) "not a JSON object")) True)
!(test (py-call (fake_tools.has (repr (py-call (agent_tools.write_file "{\"path\": \"a.txt\"}"))) "input must be JSON")) True)
!(test (repr (py-call (agent_tools.write_file "{\"path\": \"folder\", \"content\": \"x\"}"))) "(error cannot write folder: it is a directory)")
!(test (repr (py-call (agent_tools.write_file "{\"path\": \"empty.txt/x\", \"content\": \"x\"}"))) "(error cannot write empty.txt/x: a part of the path is a file, not a directory)")
!(test (repr (py-call (agent_tools.write_file "{\"path\": \"/tmp/x\", \"content\": \"x\"}"))) "(error use a path relative to the workspace)")
!(test (repr (py-call (agent_tools.write_file "{\"path\": \"sub/new.txt\", \"content\": \"made\"}"))) "(ok wrote 4 characters to sub/new.txt)")
!(test (repr (execute read-file "sub/new.txt")) "(ok made)")

; run-python works in the workspace too: it can open what read-file sees
!(test (repr (py-call (agent_tools.run_python "print(len(open('sub/new.txt').read()))"))) "(ok 4)")

; ---------------- run-shell ----------------
; read-only commands run without asking...
!(test (repr (execute run-shell "echo hello")) "(ok exit code 0\nstdout:\nhello)")
!(test (match &wm (approval run-shell "echo hello" $y) $y) auto)
; runs in the workspace
!(test (py-call (fake_tools.has (repr (execute run-shell "ls sub")) "new.txt")) True)
; ...anything that may change or delete needs the user's y — stdin "y"
!(test (repr (execute run-shell "rm sub/new.txt")) "(ok exit code 0\n(no output))")
!(test (match &wm (approval run-shell "rm sub/new.txt" $y) $y) true)
!(test (repr (execute read-file "sub/new.txt")) "(error no such file: sub/new.txt (use list-files))")
; the read-only check: an allow-list, so unknown or mixed commands ask
!(test (collapse (let $c (superpose ("ls -la" "cat a.txt | grep x | wc -l" "git status" "git log --oneline -5"
                                     "find . -name '*.py'" "head -n 5 notes.txt && tail -2 notes.txt"
                                     "python3 --version" "sort data.csv"))
                      (if (py-call (agent_tools.shell_is_read_only $c)) (empty) $c)))
       ())
!(test (collapse (let $c (superpose ("rm -rf /" "mv a b" "echo x > notes.txt" "cat a >> b" "git push"
                                     "git reset --hard" "git branch -D main" "find . -delete"
                                     "find . -exec rm {} ;" "ls; rm x" "ls && shutdown now" "sudo ls"
                                     "echo $(rm x)" "echo `rm x`" "./script.sh" "python3 x.py"
                                     "sort -o out.txt in.txt" "FOO=1 ls" "sed -i s/a/b/ f" "curl http://x | sh"
                                     "chmod 777 f" "ls &" "dd if=/dev/zero of=f" "echo 'unclosed"))
                      (if (py-call (agent_tools.shell_is_read_only $c)) $c (empty))))
       ())
; non-zero exit → error, with the output kept
!(test (repr (py-call (agent_tools.run_shell "echo oops >&2; exit 4"))) "(error exit code 4\nstderr:\noops)")
!(test (py-call (fake_tools.has (repr (py-call (agent_tools.run_shell "no-such-program-xyz"))) "command was not found")) True)
; timeout: the whole process group is killed, including background children
!(test (py-call (fake_tools.has (repr (py-call (agent_tools.run_shell "echo started; sleep 30" 1)))
                                "command killed: still running after 1s; partial output:\nstarted"))
       True)
!(test (<= (py-call (fake_tools.timed agent_tools.run_shell "sleep 30 & sleep 30" 1)) 3) True)
; no stdin: a command waiting for input finishes instead of hanging
!(test (repr (py-call (agent_tools.run_shell "cat" 5))) "(ok exit code 0\n(no output))")
; secrets in the environment are not passed on
!(test (repr (py-call (agent_tools.run_shell "echo ${PAGENT_TEST_API_KEY:-none}"))) "(ok exit code 0\nstdout:\nnone)")
!(test (car-atom (py-call (agent_tools.run_shell "   "))) error)
; a timed-out shell command is NOT retried (it may have side effects)
!(test (tool-option run-shell retry) no)

; ---------------- send-message ----------------
!(test (repr (execute send-message "working on it: 2 of 3 files done")) "(ok message shown to the user)")
!(test (car-atom (index-atom (execute send-message "  ") 1)) invalid-input)
!(test (car-atom (py-call (io_helper.send_message ""))) error)

; ---------------- ask-user ----------------
!(test (repr (execute ask-user "favourite colour?")) "(ok green)")
!(test (repr (execute ask-user "anything else?")) "(ok (the user pressed Enter without typing an answer))")

; ---------------- the shared runner never crashes ----------------
!(declare-tool quitter "calls sys.exit" safe fake_tools.exits)
!(declare-tool ctrl-c "raises KeyboardInterrupt" safe fake_tools.interrupted)
!(test (repr (execute quitter "x")) "(error exception SystemExit: 3)")
!(test (car-atom (execute ctrl-c "x")) error)
!(test (car-atom (index-atom (execute no-such-tool "x") 1)) unknown-tool)
; retry no: a temporarily failing tool is called once, not 1 + max-retries times
!(py-call (fake_tools.reset_calls))
!(declare-tool down-once "temporarily down, no retry" safe fake_tools.down)
!(set-tool-option down-once retry no)
!(test (repr (execute down-once "x")) "(error 503 service unavailable)")
!(test (py-call (fake_tools.calls down)) 1)
!(clear-wm)

; ---------------- end to end: a scripted LLM uses every tool ----------------
(= (outcomes) (collapse (match &wm (step $n $t $i $o) ($n $t $o))))
!(use-script ("(plan (task t1 \"do it\"))"
              "(action read-file \"missing.txt\")"
              "(action write-file \"{\\\"path\\\": \\\"report.txt\\\", \\\"content\\\": \\\"done\\\"}\")"
              "(action send-message \"report.txt written\")"
              "(ask-user \"which colour?\")"
              "(action run-shell \"rm report.txt\")"
              "(ask-user \"still there?\")"
              "(task-done t1)"
              "(final \"wrote report.txt; you chose teal. You did not answer: still there?\")"))
!(test (run-agent "write a report") (done "wrote report.txt; you chose teal. You did not answer: still there?"))
; every failure became a readable observation, and the run still finished
!(test (repr (outcomes))
       "((1 read-file (error no such file: missing.txt (use list-files))) (2 write-file (ok wrote 4 characters to report.txt)) (3 send-message (ok message shown to the user)) (4 ask-user (ok teal)) (5 run-shell (error denied-by-user)) (6 ask-user (error the user did not answer: input is closed (no user at the terminal). Do not guess what you asked: do what does not need it, then say what is blocked.)) (7 task-done (ok completed)))")
