; builtin.metta — P-agent's built-in tools, memory tools and skills.
; Loaded by my_capabilities.metta. Add your own there (or here).

!(import! &self "agent_tools.py")
!(import! &self "capability_checks.py")

; ============================================================ tools (Python)
!(declare-tool calc "evaluate arithmetic exactly, e.g. (17*23)+(144/12) or 2480*0.15. Use it for ANY calculation instead of computing in your head." safe agent_tools.calc)
!(set-tool-option calc example "2480*0.15")
!(set-tool-option calc pattern "[0-9+*/().%^, eE-]+")
!(set-tool-option calc max-length 300)

!(declare-tool wiki-search "search Wikipedia for ENCYCLOPEDIC facts (people, places, history, science, definitions); input is a short query: the topic or article title from YOUR goal. Returns the best article's summary." safe agent_tools.wiki_search)
!(set-tool-option wiki-search example "TOPIC FROM THE GOAL")   ; a placeholder: a real topic got copied
!(set-tool-option wiki-search max-length 200)
!(set-tool-option wiki-search timeout 25)
!(set-tool-option wiki-search retries 1)

!(declare-tool web-search "search the web (DuckDuckGo) for CURRENT or specific facts (news, prices, versions, recent events, products); input is a short query. Returns the top results: title, url and snippet. Use http-get on a url to read the page." safe agent_tools.web_search)
!(set-tool-option web-search example "Python 3.13 release date")
!(set-tool-option web-search max-length 300)
!(set-tool-option web-search timeout 25)
!(set-tool-option web-search retries 1)

!(declare-tool list-files "list the files in the workspace folder. Use it first when a file name is unknown or unclear (input: anything)" safe agent_tools.list_files)
!(set-tool-option list-files example ".")
!(set-tool-option list-files allow-empty yes)
!(declare-tool read-file "read a text file from the workspace; input is its relative path, e.g. notes.txt or src/main.py (use list-files first if unsure)" safe agent_tools.read_file)
!(set-tool-option read-file example "notes.txt")
!(set-tool-option read-file max-length 300)
!(set-tool-option read-file max-output 20000)

!(declare-tool write-file "write a text file in the workspace: path and content as TWO strings (shown below; \\n for a new line). JSON {\"path\": ..., \"content\": ...} also works." needs-approval agent_tools.write_file)
!(set-tool-option write-file example "(action write-file \"notes/out.txt\" \"line 1\\nline 2\")")
!(set-tool-option write-file max-length 100000)
!(set-tool-option write-file retry no)        ; one approval = one write
!(set-tool-option write-file auto-approve agent_tools.write_is_new_file)   ; asks only to OVERWRITE

!(declare-tool run-python "run a short Python 3 program and return what it prints; use print(). Separate process, runs in the workspace folder (open files by their workspace path), 15s limit, no third-party packages." needs-approval agent_tools.run_python)
!(set-tool-option run-python example "print(sum(range(1, 11)))")
!(set-tool-option run-python timeout 25)
!(set-tool-option run-python max-length 20000)
!(set-tool-option run-python max-output 8000)
!(set-tool-option run-python retry no)        ; "timed out" looks temporary, but one approval = one run

!(declare-tool run-shell "run a shell command (sh) in the workspace folder and return its exit code, stdout and stderr, e.g. ls -la or grep -n TODO notes.txt. Non-interactive (no stdin), 60s limit. Read-only commands run at once; anything that may change or delete something waits for the user's approval." needs-approval agent_tools.run_shell)
!(set-tool-option run-shell example "grep -n TODO notes.txt")
!(set-tool-option run-shell auto-approve agent_tools.shell_is_read_only)   ; asks for anything else
!(set-tool-option run-shell max-length 4000)
!(set-tool-option run-shell max-output 16000)
!(set-tool-option run-shell timeout 75)     ; > the 60s kill inside run_shell, so it reports first
!(set-tool-option run-shell retry no)       ; a command with side effects must not run twice

!(declare-tool http-get "GET a public http(s) URL you found (a search result or a link in a page); a web page comes back as its readable text. Binary files (PDF) are refused." needs-approval agent_tools.http_get)
!(set-tool-option http-get example "URL FROM YOUR SEARCH RESULTS")   ; not a URL: copied as is, the pattern refuses it before any approval
!(set-tool-option http-get pattern "https?://\\S+")
!(set-tool-option http-get timeout 20)
!(set-tool-option http-get retries 1)         ; one retry: a dead site costs 40 s, not 80
!(set-tool-option http-get max-output 15000)   ; a page's readable text, not just its first lines
!(set-tool-option http-get remember-approval yes) ; a GET is safe to repeat: approve a URL once per session

!(declare-tool arxiv-search "research papers with title, authors, date, url and full abstract (no http-get needed). Input: words, or latest + words for newest first; a category like cs.LG cs.AI cs.CL cs.CV stat.ML; | N for how many (default 5). E.g. latest cs.LG | 5" safe agent_tools.arxiv_search)
!(set-tool-option arxiv-search example "latest cs.LG | 5")
!(set-tool-option arxiv-search timeout 30)
!(set-tool-option arxiv-search retries 1)
!(set-tool-option arxiv-search max-length 300)
!(set-tool-option arxiv-search max-output 15000)

!(declare-tool now "the current date and time: for today, this year, ages, deadlines, how long ago (input: anything)" safe agent_tools.now)
!(set-tool-option now example "now")
!(set-tool-option now allow-empty yes)

; ============================================================ tools (MeTTa → AtomSpace)
; These run INSIDE PeTTa and query the long-term AtomSpace &kb directly.

!(declare-tool memory-search "search long-term memory (facts learned in earlier sessions and past tasks); input is a short query" safe metta)
!(set-tool-option memory-search example "capital of france")
!(declare-tool memory-store "store a fact in long-term memory; input is an S-expression like (capital france paris). Never secrets." safe metta)
!(set-tool-option memory-store example "(capital france paris)")

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

; ============================================================ evidence for every goal
; a file the final answer says was saved must exist (a failed write-file is no file)
!(declare-verifier capability_checks.claimed_files_exist)

; ============================================================ skills
!(declare-skill research "find facts and answer factual questions"
                (web-search wiki-search memory-search)
                (who what when where which find search research history born capital population largest highest founded invented area height wikipedia))
!(set-skill-info research procedure "1. memory-search first: it may already be known. 2. web-search (current or specific facts) or wiki-search (encyclopedic facts) with a SHORT query. 3. If the snippets lack the fact, http-get the best url or search again with different words. 4. For trends, overviews or a report: read 2-3 DIFFERENT sources (http-get several results, or search with other words), not just the first hit. 5. Answer only from observations and name every source.")
!(set-skill-info research output "the answer + which article it came from")
!(set-skill-info research on-error "if wiki-search fails twice, try http-get on https://en.wikipedia.org/wiki/TITLE. If a page is unreadable or off-topic, move to the next search result - never clean HTML with shell commands. Otherwise say what could not be found")
!(set-skill-verifier research capability_checks.number_is_observed)

!(declare-skill math "solve calculations and word problems"
                (calc)
                (calculate compute sum total percent percentage multiply divide plus minus average how many much math equation times add subtract product difference))
!(set-skill-info math procedure "1. turn the question into ONE arithmetic expression. 2. calc it. 3. Answer with the number and its unit.")
!(set-skill-info math output "the number, with units")
!(set-skill-info math on-error "if calc rejects the input, rewrite it with only digits and + - * / ( ) and retry")
!(set-skill-verifier math capability_checks.has_number)
!(set-skill-verifier math capability_checks.computed_by_tool)   ; calc must have run
!(set-conclusive-verifier math capability_checks.answer_is_tool_result) ; the answer IS calc's result: no semantic LLM check needed

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

!(declare-skill papers "find recent research papers and summarize them"
                (arxiv-search write-file)
                (paper papers arxiv preprint preprints publication publications journal conference))
!(set-skill-info papers procedure "1. arxiv-search ONCE: latest + a category for the newest papers of a field (cs.LG machine learning, cs.AI, cs.CL language, cs.CV vision, stat.ML), or plain words for the most relevant ones; | N for how many. Its results already contain each abstract: do not http-get the papers or their PDFs. 2. Pick the papers that best fit the goal. 3. Summarize each from its abstract yourself (do not delegate): title, authors, date, 2-4 key points, url. 4. To save them: ONE write-file (e.g. papers_summary.md). 5. Final answer: the summaries and the file name.")
!(set-skill-info papers output "for each paper: title, authors, date, key points, link; plus the saved file name")
!(set-skill-info papers on-error "if arxiv-search finds nothing, use fewer words or a category; if it is unreachable, web-search and http-get the arxiv.org/abs/ pages")

!(declare-skill summarization "summarise a document"
                (read-file)
                (summarise summarize summary tldr overview brief shorten key points))
!(set-skill-info summarization procedure "1. Use the text already in the steps (a fetched page, search results, abstracts); read-file only when it is in a file. 2. Pick the 3-5 most important points. 3. Write them in plain language; keep names and numbers exact.")
!(set-skill-info summarization output "a short summary that keeps key names and figures")
!(set-skill-info summarization on-error "if the file is too long, summarise what was read and say it was truncated")
