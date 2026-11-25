; main.metta — P-agent command line.   sh run.sh main.metta   (Ubuntu Bash)
;
; Your tools and skills go in my_capabilities.metta (imported below).
; Commands: help tools skills memory quit — anything else is a goal.
; While the agent works, type c + Enter to cancel the current goal.
;
; This file is only the INTERFACE: it reads input and renders results.
; The agent itself is core/agent.metta, unchanged by any interface.

!(import! &self core/agent)
!(import! &self my_capabilities)

!(set-config ui pretty)                ; render events with core/ui.py
!(set-config fast-plan on)             ; short single-step goals skip the planning LLM call
!(set-config repair-replies on)        ; an unusable reply is asked for again at once, with its format

; long-term memory file; PAGENT_KB overrides it (tests use their own file)
(= (kb-path) (py-call (os.getenv "PAGENT_KB" "data/kb.metta")))
!(load-space &kb (kb-path))

(= (save-memory) (save-space &kb (kb-path)))

(= (skill-rows)
   (collapse (let $s (match &caps (skill $n $d) $n)
                  ($s (if (skill-available $s) available (missing (missing-tools $s)))))))

; session transcript (everything shown and typed) → logs/session-*.log
!(py-call (ui.start_log))
!(py-call (ui.banner (tool-catalog) (skill-catalog) (memory-stats)))

; One goal. Whatever happens inside — even an internal error — the session
; goes on and waits for the next goal: no restart needed.
(= (run-goal $goal)
   (let* (($n (+ 1 (py-call (session.count))))
          ($h (py-call (ui.task_header $n $goal)))
          ($r (catch (run-agent $goal))))
         (case $r
               (((Error $where $why)
                   (let $e (py-call (session.record $goal (repr (stopped (internal-error $why)))))
                        (py-call (ui.internal_error (repr $why)))))
                ($ok (py-call (ui.show_result $r)))))))

(= (command $c)
   (case $c
         ((help   (py-call (ui.help_text)))
          (tools  (py-call (ui.list_rows "Tools (name description permission)" (tool-catalog))))
          (skills (py-call (ui.list_rows "Skills" (skill-rows))))
          (memory (let* (($a (py-call (ui.list_rows "Memory" (collapse (match &kb (fact $c2 (meta $s $t $conf)) ($c2 $conf))))))
                         ($stats (memory-stats)))
                        (py-call (ui.list_rows "Stats" ($stats)))))
          (history (py-call (ui.show_text "This session" (py-call (session.summary)))))
          ($goal  (let $r (run-goal $goal)
                       (save-memory))))))          ; after every goal: crash-safe

(= (cli)
   (let $input (py-call (io_helper.read_goal))
        (if (or (== $input quit) (== $input exit))
            (let $s (save-memory) (py-call (ui.quit_now)))
            (let $r (command $input) (cli)))))

!(cli)
