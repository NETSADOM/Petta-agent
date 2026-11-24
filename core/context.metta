; context.metta — Context Manager: decides WHAT the LLM sees, and how much.
; Every piece is chosen by PeTTa from the AtomSpaces:
;
;   goal              &wm (goal ..)
;   plan + current    &wm tasks; the current task's skill guide from &caps
;   steps             &wm steps — WINDOWED: last context-steps in full (clipped to
;                     context-obs-chars); the context-older-steps before them in
;                     SHORT form (context-older-chars), so findings from turn 3 are
;                     still visible at turn 30; anything older only counted
;   progress          turn N of max-iterations — the model paces long tasks
;   tools / skills    &caps catalogs; skills relevant to the goal with full guides
;   facts             &kb (long-term AtomSpace): only facts relevant to the goal
;   episodes          &kb: similar past runs (what worked)
;   recovery hints    after a failure: class, alternatives, learned fixes
;
; Why a window: every iteration re-sends the context to the LLM. Unbounded
; history makes each call slower and costlier, and overflows small local models.
; Verification (verify.metta) uses (all-steps-repr): it must see all evidence.

!(import! &self "session.py")       ; earlier goals of this CLI session (bounded)
!(set-config context-steps 8)        ; recent steps shown in full
!(set-config context-obs-chars 600)  ; max characters per step input/outcome
!(set-config context-older-steps 20) ; the older steps kept in short form (only these)
!(set-config context-older-chars 120); max characters per short outcome
!(set-config max-iterations 40)     ; turns (LLM calls) per goal; shown as PROGRESS, enforced by agent.metta

(= (skills-of-task $id) (collapse (match &wm (task-skill $id $s) $s)))

(= (tasks-repr) (repr (collapse (match &wm (task $i $d $s) ($i $d $s)))))

; clip a value for the prompt (display only — never stored)
(= (clip-to $x $n)
   (if (> (py-call (toolrunner.length (repr $x))) $n)
       (py-call (memory.shorten (repr $x) $n))
       $x))
(= (clip $x) (clip-to $x (config-value context-obs-chars)))

(= (step-view $n $t $i $o) ($n $t (clip $i) (clip $o)))

(= (short $x $n) (clip-to $x $n))

; older steps: the very oldest only counted; then the most recent
; context-older-steps of them in short form (n tool input outcome)
;   ((earlier-steps N ok A failed B (failed-tools ...)) (3 read-file "notes.txt" "(ok launch ...") ...)
(= (older-summary $cut)
   (let $old (collapse (match &wm (step $n $t $i $o) (if (<= $n $cut) ($n $t $o) (empty))))
        (if (== $old ())
            ()
            (let* (($failed (collapse (let $s (superpose $old)
                                           (if (== (car-atom (index-atom $s 2)) error) (index-atom $s 1) (empty)))))
                   ($nf (size-atom $failed))
                   ($from (- $cut (config-value context-older-steps)))
                   ($k (config-value context-older-chars))
                   ($brief (sort-atom (collapse (match &wm (step $n $t $i $o)
                                                       (if (and (<= $n $cut) (> $n $from))
                                                           ($n $t (short $i 60) (short $o $k))
                                                           (empty)))))))
                  (cons-atom (earlier-steps (size-atom $old) ok (- (size-atom $old) $nf) failed $nf
                                            (failed-tools (unique-atom $failed)))
                             $brief)))))

(= (steps-repr)
   (let* (($cut (- (step-count) (config-value context-steps)))
          ($recent (sort-atom (collapse (match &wm (step $n $t $i $o)
                                               (if (> $n $cut) (step-view $n $t $i $o) (empty))))))
          ($summary (older-summary $cut)))
         (repr (union-atom $summary $recent))))

; every step (clipped), for verification: evidence must not be windowed away
(= (all-steps-repr)
   (repr (sort-atom (collapse (match &wm (step $n $t $i $o) (step-view $n $t $i $o))))))

; only facts relevant to this goal (memory.metta ranks them), not the whole &kb
(= (facts-repr) (repr (relevant-facts (goal-text))))
(= (episodes-repr) (repr (similar-episodes (goal-text))))

; PeTTa picks the relevant skills; the LLM sees their full procedures.
(= (plan-request)
   (py-call (prompts.plan_prompt (goal-text) (repr (tool-catalog)) (repr (skill-catalog))
                                 (repr (relevant-skill-details (goal-text)))
                                 (tasks-repr) (steps-repr) (facts-repr) (episodes-repr)
                                 (py-call (session.summary)))))

; the current task and the guide of the skill it uses
(= (current-task-repr)
   (let $t (current-task)
        (if (== $t none)
            "none"
            (repr ($t (collapse (match &wm (task $t $d $s) $d))
                      (map-atom (skills-of-task $t) $s (skill-detail $s)))))))

(= (act-request)
   (py-call (prompts.act_prompt (goal-text) (tasks-repr) (current-task-repr) (steps-repr)
                                (repr (tool-catalog)) (facts-repr) (repr (recovery-hints))
                                (current-turn) (config-value max-iterations)
                                (py-call (session.summary)))))

; size of what is sent each iteration (for measuring)
(= (context-chars) (py-call (toolrunner.length (act-request))))
