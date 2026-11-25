; my_capabilities.metta — the agent's tools and skills (imported by main.metta).
;
; Built-in set (capabilities/builtin.metta):
;   tools   calc, web-search, wiki-search, list-files, read-file, write-file*, run-python*,
;           run-shell*, http-get*, now, memory-search, memory-store   (* = asks you y/N)
; Always present (core/agent.metta): send-message, ask-user
;   skills  research, math, file-analysis, data-analysis, coding, shell, summarization
; Skill folders (skills/NAME/SKILL.md): code-review
!(import! &self capabilities/builtin)
!(load-skills "skills")

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
; A short skill, in MeTTa:
;   !(declare-skill travel "plan trips" (weather wiki-search) (trip travel visit flight))
;   !(set-skill-info travel procedure "1. ... 2. ...")
;
; A long skill, as a folder (loaded by load-skills above), skills/travel/SKILL.md:
;   ---
;   name: travel
;   description: plan trips: routes, weather, what to visit
;   tools: weather, wiki-search
;   keywords: trip travel visit flight        (optional: the description counts too)
;   ---
;   Any Markdown guide, as long as it needs to be. Extra files next to it
;   (skills/travel/visas.md) are read only when needed: read-skill travel/visas.md
;
; Recovery and verification:
;   !(declare-alternative weather http-get)
;   !(declare-verifier my_checks.no_empty_answer)
