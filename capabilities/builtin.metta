; builtin.metta — P-agent's built-in tools, memory tools and skills.
; Loaded by my_capabilities.metta. Add your own there (or here).

!(import! &self "agent_tools.py")
!(import! &self "capability_checks.py")

; ============================================================ tools (Python)
!(declare-tool calc "evaluate arithmetic exactly, e.g. (17*23)+(144/12) or 2480*0.15. Use it for ANY calculation instead of computing in your head." safe agent_tools.calc)
!(set-tool-option calc pattern "[0-9+*/().%^, eE-]+")
!(set-tool-option calc max-length 300)

!(declare-tool wiki-search "search Wikipedia; input is a short query like 'Lake Tana area'. Returns the best article's summary." safe agent_tools.wiki_search)
!(set-tool-option wiki-search max-length 200)
!(set-tool-option wiki-search timeout 25)

!(declare-tool web-search "search the web (DuckDuckGo); input is a short query. Returns the top results: title, url and snippet. Use http-get on a url to read the page." safe agent_tools.web_search)
!(set-tool-option web-search max-length 300)
!(set-tool-option web-search timeout 25)

!(declare-tool list-files "list the files in the workspace folder (input: anything)" safe agent_tools.list_files)
!(set-tool-option list-files allow-empty yes)
!(declare-tool read-file "read a text file from the workspace; input is its relative path, e.g. data/sales.csv" safe agent_tools.read_file)
!(set-tool-option read-file max-length 300)
!(set-tool-option read-file max-output 20000)

!(declare-tool write-file "write a text file in the workspace; input is JSON {\"path\": \"notes/out.txt\", \"content\": \"...\"}" needs-approval agent_tools.write_file)
!(set-tool-option write-file max-length 100000)
!(set-tool-option write-file auto-approve agent_tools.write_is_new_file)   ; asks only to OVERWRITE

!(declare-tool run-python "run a short Python 3 program and return what it prints; use print(). Separate process, runs in the workspace folder (open files by their workspace path), 15s limit, no third-party packages." needs-approval agent_tools.run_python)
!(set-tool-option run-python timeout 25)
!(set-tool-option run-python max-length 20000)
!(set-tool-option run-python max-output 8000)

!(declare-tool run-shell "run a shell command (sh) in the workspace folder and return its exit code, stdout and stderr, e.g. ls -la or grep -n TODO notes.txt. Non-interactive (no stdin), 60s limit. Read-only commands run at once; anything that may change or delete something waits for the user's approval." needs-approval agent_tools.run_shell)
!(set-tool-option run-shell auto-approve agent_tools.shell_is_read_only)   ; asks for anything else
!(set-tool-option run-shell max-length 4000)
!(set-tool-option run-shell max-output 16000)
!(set-tool-option run-shell timeout 75)     ; > the 60s kill inside run_shell, so it reports first
!(set-tool-option run-shell retry no)       ; a command with side effects must not run twice

!(declare-tool http-get "GET a public http(s) URL (e.g. a JSON API) and return the body as text" needs-approval agent_tools.http_get)
!(set-tool-option http-get pattern "https?://\\S+")
!(set-tool-option http-get timeout 20)

!(declare-tool now "the current date and time (input: anything)" safe agent_tools.now)
!(set-tool-option now allow-empty yes)

; ============================================================ tools (MeTTa → AtomSpace)
; These run INSIDE PeTTa and query the long-term AtomSpace &kb directly.

!(declare-tool memory-search "search long-term memory (facts learned in earlier sessions and past tasks); input is a short query" safe metta)
!(declare-tool memory-store "store a fact in long-term memory; input is an S-expression like (capital france paris). Never secrets." safe metta)

(= (metta-tool memory-search $query)
   (let* (($facts (relevant-facts $query))
          ($past (similar-episodes $query)))
         (if (and (== $facts ()) (== $past ()))
             (ok "nothing relevant in long-term memory")
             (ok (memory (facts $facts) (past-tasks $past))))))

; same gates as (learn ...): structure, confidence, size, sensitivity
(= (metta-tool memory-store $text)
   (case (catch (sread $text))
         (((Error $a $b) (error "input must be an S-expression like (capital france paris)"))
          ($c (learn-fact $c 0.8 agent)))))

; ============================================================ recovery
!(declare-alternative web-search wiki-search)
!(declare-alternative wiki-search web-search)
!(declare-alternative wiki-search memory-search)
!(declare-alternative wiki-search http-get)

; ============================================================ skills
!(declare-skill research "find facts and answer factual questions"
                (web-search wiki-search memory-search)
                (who what when where which find search research history born capital population largest highest founded invented area height wikipedia))
!(set-skill-info research procedure "1. memory-search first: it may already be known. 2. web-search (current or specific facts) or wiki-search (encyclopedic facts) with a SHORT query. 3. If the snippets lack the fact, http-get the best url or search again with different words. 4. Answer only from observations and name the source.")
!(set-skill-info research output "the answer + which article it came from")
!(set-skill-info research on-error "if wiki-search fails twice, try http-get on https://en.wikipedia.org/wiki/TITLE, or say what could not be found")
!(set-skill-verifier research capability_checks.number_is_observed)

!(declare-skill math "solve calculations and word problems"
                (calc)
                (calculate compute sum total percent percentage multiply divide plus minus average how many much math equation times))
!(set-skill-info math procedure "1. turn the question into ONE arithmetic expression. 2. calc it. 3. Answer with the number and its unit.")
!(set-skill-info math output "the number, with units")
!(set-skill-info math on-error "if calc rejects the input, rewrite it with only digits and + - * / ( ) and retry")
!(set-skill-verifier math capability_checks.has_number)

!(declare-skill file-analysis "answer questions about files in the workspace"
                (list-files read-file)
                (file files read document csv txt notes report folder workspace open))
!(set-skill-info file-analysis procedure "1. list-files if the name is unclear. 2. read-file. 3. Quote or compute from the actual content (calc for arithmetic).")
!(set-skill-info file-analysis output "the answer + which file and lines it comes from")
!(set-skill-info file-analysis on-error "if the file is missing, list-files and pick the closest name; never guess its content")

!(declare-skill data-analysis "compute statistics over tabular data (csv)"
                (read-file run-python calc)
                (data csv analyse analyze statistics average mean median total revenue rows columns trend table))
!(set-skill-info data-analysis procedure "1. read-file to see the columns. 2. For more than a few rows, run-python: paste the data into the program and print the result. 3. Report the figures.")
!(set-skill-info data-analysis output "the computed figures and how they were computed")
!(set-skill-info data-analysis on-error "if run-python is refused, compute with calc row by row")

!(declare-skill coding "write, run and debug Python code"
                (run-python write-file read-file)
                (code python script program function debug bug implement algorithm test))
!(set-skill-info coding procedure "1. write the smallest program that answers the question. 2. run-python with print() statements. 3. On an error, read the traceback, fix, run again. 4. write-file only if the user wants the code saved.")
!(set-skill-info coding output "the working code and its output")
!(set-skill-info coding on-error "fix the exact line from the traceback; after 3 failed runs explain what blocks it")

!(declare-skill shell "run commands on this machine: inspect folders, search text, use installed programs"
                (run-shell read-file write-file)
                (shell command terminal bash run execute grep ls directory folder git install disk process))
!(set-skill-info shell procedure "1. run-shell one small, non-interactive command at a time. 2. Read the exit code: 0 = success; otherwise read stderr. 3. Fix the command and run again, or explain what blocks it.")
!(set-skill-info shell output "what the command showed, quoted exactly where it matters")
!(set-skill-info shell on-error "exit code 127 = command not found: try another program; 'killed: still running' = make the command smaller or non-interactive; denied = do it another way or ask-user")

!(declare-skill summarization "summarise a document"
                (read-file)
                (summarise summarize summary tldr overview brief shorten key points))
!(set-skill-info summarization procedure "1. read-file. 2. Pick the 3-5 most important points. 3. Write them in plain language; keep names and numbers exact.")
!(set-skill-info summarization output "a short summary that keeps key names and figures")
!(set-skill-info summarization on-error "if the file is too long, summarise what was read and say it was truncated")
