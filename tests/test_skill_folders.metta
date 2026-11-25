; Skill folders (SKILL.md), selection without exact keywords, and read-skill.

!(import! &self ../core/agent)
!(import! &self "fake_tools.py")
!(set-config retry-backoff 0)

!(declare-tool upper "uppercase text" safe fake_tools.upper)
!(declare-skill shouting "make text loud" (upper) (shout loud))
!(set-skill-info shouting procedure "1. call upper 2. report")

; ---------------- loading a folder of skills ----------------
; one result per folder; a bad SKILL.md is reported, never half-loaded
!(test (load-skills "tests/skills")
       ((error (bad-skill-folder "broken" "description is required: it is how the LLM decides to use the skill"))
        (loaded-skill loud-report)))
!(test (skill-known broken) False)
!(test (skill-available loud-report) True)
!(test (collapse (match &caps (skill-needs loud-report $t) $t)) (upper))
!(test (skill-files loud-report) ("notes.md"))
!(test (load-skills "no/such/folder") ())
; loading twice is refused like any duplicate skill
!(test (car-atom (load-skills "tests/skills")) (error (bad-skill-folder "broken" "description is required: it is how the LLM decides to use the skill")))
!(test (index-atom (load-skills "tests/skills") 1) (error (duplicate-skill loud-report)))

; the whole Markdown body is the guide: newlines and quotes survive
!(test (py-call (operator.contains (match &caps (skill-info loud-report guide $g) $g) "LOUD-GUIDE-MARKER")) True)
!(test (py-call (operator.contains (match &caps (skill-info loud-report guide $g) $g) "1. Collect the result to announce.\n2. Call upper")) True)

; ---------------- selection: stems, names, descriptions ----------------
; loud-report has NO keywords: its description is enough ("announcing" ~ "announce")
!(test (relevant-skills "we are announcing the results") (loud-report))
; word forms meet: "shouts" ~ "shout", "louder"? no (stemming is light)
!(test (relevant-skills "she shouts") (shouting))
!(test (skill-score shouting "make it loud") 1)        ; "make" is filler, not a hit
!(test (relevant-skills "hello") ())

; ---------------- what the planner sees: summaries ----------------
!(clear-tasks)
!(set-goal "announce the results to everyone")
!(test (py-call (operator.contains (plan-request) "### skill loud-report")) True)
!(test (py-call (operator.contains (plan-request) "LOUD-GUIDE-MARKER")) True)
!(test (py-call (operator.contains (plan-request) "LONG-TAIL-MARKER")) False)       ; cut
!(test (py-call (operator.contains (plan-request) "read-skill \"loud-report/FILE\"")) True)
; every available skill is listed, matched or not
!(test (py-call (operator.contains (plan-request) "make text loud")) True)

; ---------------- what the actor sees: the full guide of its task's skill ----------------
!(load-plan (plan (task t1 "announce it" (uses loud-report))))
!(test (py-call (operator.contains (act-request) "LONG-TAIL-MARKER")) True)
!(test (py-call (operator.contains (act-request) "Skills you can load with read-skill")) True)
; a task without a skill gets the hint to load one
!(load-plan (plan (task t1 "announce it")))
!(test (py-call (operator.contains (act-request) "Skill guide: none")) True)
!(test (py-call (operator.contains (act-request) "LONG-TAIL-MARKER")) False)

; ---------------- read-skill ----------------
!(test (execute read-skill "loud-report")
       (ok (skill-loaded loud-report (for-task t1) "its full guide is now shown under CURRENT TASK" (files ("notes.md")))))
!(test (skills-of-task t1) (loud-report))
!(test (execute read-skill "loud-report")
       (ok (skill-loaded loud-report (for-task t1) "its full guide is now shown under CURRENT TASK" (files ("notes.md")))))
!(test (skills-of-task t1) (loud-report))                 ; attached once
!(test (py-call (operator.contains (act-request) "LONG-TAIL-MARKER")) True)
; extra files, confined to the skill folder
!(test (py-call (operator.contains (index-atom (execute read-skill "loud-report/notes.md") 1) "NOTICE:")) True)
!(test (car-atom (execute read-skill "loud-report/../broken/SKILL.md")) error)
!(test (car-atom (execute read-skill "loud-report/nope.md")) error)
!(test (car-atom (execute read-skill "shouting/x.md")) error)            ; MeTTa skill: no files
!(test (car-atom (execute read-skill "dancing")) error)
!(test (car-atom (execute read-skill "Not A Name!")) error)
; a MeTTa-written skill attaches the same way
!(test (car-atom (execute read-skill "shouting")) ok)
!(test (skills-of-task t1) (loud-report shouting))

; ---------------- full loop: the model loads a skill the planner did not pick ----------------
!(use-script ("(plan (task t1 \"announce the score\"))"
              "(action read-skill \"loud-report\")"
              "(action upper \"score is 3\")"
              "(task-done t1)"
              "(final \"SCORE IS 3\")"))
!(test (run-agent "tell everybody the score is 3") (done "SCORE IS 3"))
!(test (car-atom (match &wm (step $n read-skill "loud-report" $o) $o)) ok)
!(test (match &wm (task-skill t1 $s) $s) loud-report)
