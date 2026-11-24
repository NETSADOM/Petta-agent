; my_capabilities.metta — the agent's tools and skills (imported by main.metta).
;
; Built-in set (capabilities/builtin.metta):
;   tools   calc, wiki-search, list-files, read-file, write-file*, run-python*,
;           run-shell*, http-get*, now, memory-search, memory-store   (* = asks you y/N)
; Always present (core/agent.metta): send-message, ask-user
;   skills  research, math, file-analysis, data-analysis, coding, summarization
!(import! &self capabilities/builtin)

; ---------------------------------------------------------------- your own
; A Python tool: fn(input_text) → ["ok", result] or ["error", "why"]
;   !(import! &self "my_tools.py")
;   !(declare-tool weather "current weather for a city" safe my_tools.weather)
;   !(set-tool-option weather timeout 10)
;
; A MeTTa tool (can query the AtomSpaces):
;   !(declare-tool count-facts "how many facts are in memory" safe metta)
;   (= (metta-tool count-facts $in) (ok (fact-count)))
;
; A skill:
;   !(declare-skill travel "plan trips" (weather wiki-search) (trip travel visit flight))
;   !(set-skill-info travel procedure "1. ... 2. ...")
;
; Recovery and verification:
;   !(declare-alternative weather http-get)
;   !(declare-verifier my_checks.no_empty_answer)
