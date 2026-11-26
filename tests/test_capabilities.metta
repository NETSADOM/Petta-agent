; Built-in tools, memory tools (AtomSpace) and skills.
; stdin (run_tests.sh): "y" approves write-file, "n" refuses run-python.

!(import! &self "fake_openai.py")
!(py-call (fake_openai.set_env "PAGENT_WORKSPACE" "data/test_workspace"))
!(import! &self ../core/agent)
!(import! &self ../my_capabilities)
!(set-config retry-backoff 0)

; ---------------- calc ----------------
!(test (repr (execute calc "(17*23)+(144/12)")) "(ok 403)")
!(test (repr (execute calc "2^10")) "(ok 1024)")
!(test (repr (execute calc "2,480*0.15")) "(ok 372)")
!(test (repr (execute calc "1/0")) "(error division by zero)")
!(test (car-atom (index-atom (execute calc "__import__('os').system('ls')") 1)) invalid-input)
; even past the gate pattern, the AST evaluator refuses names and calls
!(test (index-atom (py-call (agent_tools.calc "abs(-1)")) 0) error)

; ---------------- files: confined to the workspace ----------------
!(py-call (agent_tools.write_file "{\"path\": \"notes.txt\", \"content\": \"launch moved to 17 March\"}"))
!(test (repr (execute read-file "notes.txt")) "(ok launch moved to 17 March)")
!(test (py-call (operator.contains (repr (execute list-files "")) "notes.txt")) True)
!(test (repr (execute read-file "../README.md")) "(error path leaves the workspace)")
!(test (repr (execute read-file "/etc/passwd")) "(error use a path relative to the workspace)")
!(test (repr (execute read-file "missing.txt")) "(error no such file: missing.txt (use list-files))")
; write-file: a NEW file is written without asking...
!(test (car-atom (execute write-file "{\"path\": \"out/a.txt\", \"content\": \"first\"}")) ok)
!(test (match &wm (approval write-file "{\"path\": \"out/a.txt\", \"content\": \"first\"}" $y) $y) auto)
; ...OVERWRITING an existing one needs approval — stdin answers "y"
!(test (car-atom (execute write-file "{\"path\": \"out/a.txt\", \"content\": \"hi\"}")) ok)
!(test (match &wm (approval write-file "{\"path\": \"out/a.txt\", \"content\": \"hi\"}" $y) $y) true)
!(test (repr (execute read-file "out/a.txt")) "(ok hi)")
!(test (car-atom (py-call (agent_tools.write_file "not json"))) error)

; ---------------- run-python ----------------
; refused by the user (stdin "n") → never runs
!(test (execute run-python "print(1)") (error denied-by-user))
; the tool itself (called directly): separate process, no secrets in its env
!(test (repr (py-call (agent_tools.run_python "print(sum(range(10)))"))) "(ok 45)")
!(test (car-atom (py-call (agent_tools.run_python "raise ValueError('x')"))) error)
!(test (repr (py-call (agent_tools.run_python "import os; print(os.environ.get('GEMINI_API_KEY', 'none'))"))) "(ok none)")
!(test (repr (py-call (agent_tools.run_python "```python\nprint(7*6)\n```"))) "(ok 42)")

; ---------------- http-get: public addresses only ----------------
!(test (repr (py-call (agent_tools.http_get "http://127.0.0.1:8080/"))) "(error 127.0.0.1 is a private/local address — refused)")
!(test (repr (py-call (agent_tools.http_get "http://localhost/admin"))) "(error localhost is a private/local address — refused)")
!(test (repr (py-call (agent_tools.http_get "file:///etc/passwd"))) "(error only http(s) URLs are allowed)")
!(test (car-atom (index-atom (execute http-get "ftp://x") 1)) invalid-input)   ; gate pattern
; the catalog's example is a placeholder: copied as is, it is refused BEFORE any approval
; (a real sample URL, Lake_Tana, got copied and fetched for a question about dropout)
!(test (car-atom (index-atom (execute http-get (tool-option http-get example)) 1)) invalid-input)
!(test (collapse (match &wm (approval http-get $i $y) $i)) ())
; a redirect to a private address is refused too
!(test (case (catch (py-call (fake_tools.redirect_check "http://192.168.1.1/")))
             (((Error $a $b) refused) ($x allowed)))
       refused)

; ---------------- memory tools (MeTTa, on the AtomSpace &kb) ----------------
!(test (execute memory-store "(capital kenya nairobi)") (ok remembered))
!(test (recall (capital kenya $x)) (((capital kenya nairobi) 0.8)))
!(test (py-call (operator.contains (repr (execute memory-search "capital of kenya")) "nairobi")) True)
!(test (execute memory-store "(user password \"abc\")") (error (rejected ((sensitive secret-word)))))
!(test (car-atom (execute memory-store "not an (expression")) error)
!(test (execute memory-search "quantum chromodynamics") (ok "nothing relevant in long-term memory"))

; ---------------- skills: all available, discovered by goal ----------------
!(test (collapse (let $s (match &caps (skill $n $d) $n) (if (skill-available $s) (empty) $s))) ())
!(test (car-atom (relevant-skills "what is 15 percent of 2480")) math)
; both file-analysis (file, report) and summarization (summarize) are offered; the LLM picks
!(test (is-member summarization (relevant-skills "summarize the report file")) True)
!(test (car-atom (relevant-skills "who founded the city with the largest population")) research)
!(test (is-member data-analysis (relevant-skills "average revenue in the csv data")) True)
!(test (car-atom (relevant-skills "debug my python code")) coding)
; folder skill (skills/code-review): loaded, available, found by its words
!(test (skill-available code-review) True)
!(test (is-member code-review (relevant-skills "please review my script for bugs")) True)
!(test (is-member code-review (relevant-skills "is this code readable? any risks?")) True)
!(test (skill-files code-review) ("checklist.md"))

; ---------------- objective checks ----------------
!(test (py-call (capability_checks.has_number "g" "about 42 km" "")) True)
!(test (repr (py-call (capability_checks.number_is_observed "g" "it is 9999 m" "(ok 4550)")))
       "(error 9999 does not appear in any observation)")
!(test (py-call (capability_checks.number_is_observed "g" "it is 4,550 m" "(ok 4550 metres)")) True)

; ---------------- the "easy maths, skipped calc" case (seen live with gpt-oss on Groq) ----------------
; 1. answer from its head → refused, and the hint names calc (the math skill's tool)
; 2. calc → final → accepted, the math checks (has a number, calc ran) pass
!(use-script ("(plan (task t1 \"calculate 15 percent of 2480\" (uses math)))"
              "(final \"372\")"
              "(action calc \"2480*0.15\")"
              "(final \"372\")"))
!(test (run-agent "what is 15 percent of 2480") (done "372"))
!(test (match &wm (step 1 finish $a (error (verification-failed (($u $open $why $hints))))) $hints)
       ((t1 (run-first (calc)))))
!(test (match &wm (step 2 calc $i $o) (repr $o)) "(ok 372)")
; calc ran under a task, but not for THIS answer? the math check still wants a calc result:
!(use-script ("(plan (task t1 \"calculate 15 percent of 2480\" (uses math)))"
              "(action memory-search \"15 percent of 2480\")"
              "(final \"372\")"
              "(action calc \"2480*0.15\")"
              "(final \"372\")"))
!(test (run-agent "what is 15 percent of 2480") (done "372"))
!(test (match &wm (step 2 finish $a (error (verification-failed $p))) $p)
       ((check-failed capability_checks.computed_by_tool "no calc result in the observations: run calc on the expression, then answer with its result")))
