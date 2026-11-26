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
!(set-config context-fresh-chars 12000) ; the LATEST turn's results, shared between them: the model
                                     ; reads a fetched page once, in full, instead of 600 characters
                                     ; of it (which made it fetch the same page again and again)
!(set-config context-verify-chars 4000) ; per step outcome in the VERIFY prompt, at least
!(set-config context-verify-total 38000) ; shared between the steps (prompts.py caps the total at 40000)
!(set-config context-older-steps 20) ; the older steps kept in short form (only these)
!(set-config context-older-chars 120); max characters per short outcome
!(set-config max-iterations 40)     ; turns (LLM calls) per goal; shown as PROGRESS, enforced by agent.metta

(= (skills-of-task $id) (collapse (match &wm (task-skill $id $s) $s)))

(= (tasks-repr) (repr (collapse (match &wm (task $i $d $s) ($i $d $s)))))

; clip a value for the prompt (display only — never stored)
(= (clip-to $x $n)
   (if (> (py-call (toolrunner.length (repr $x))) $n)
       (py-call (text.shorten (repr $x) $n))
       $x))
(= (clip $x) (clip-to $x (config-value context-obs-chars)))

(= (step-view $n $t $i $o) ($n $t (clip $i) (clip $o)))

; a step from the latest turn: its outcome gets a share of context-fresh-chars
(= (fresh-view $n $t $i $o $budget) ($n $t (clip $i) (clip-to $o $budget)))

(= (fresh-budget $k)
   (let $share (if (> $k 0) (/ (config-value context-fresh-chars) $k) 0)
        (if (> $share (config-value context-obs-chars)) $share (config-value context-obs-chars))))

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
          ($fresh (fresh-from))
          ($budget (fresh-budget (- (step-count) $fresh)))
          ($recent (sort-atom (collapse (match &wm (step $n $t $i $o)
                                               (if (> $n $cut)
                                                   (if (> $n $fresh)
                                                       (fresh-view $n $t $i $o $budget)
                                                       (step-view $n $t $i $o))
                                                   (empty))))))
          ($summary (older-summary $cut)))
         (repr (union-atom $summary $recent))))

; every step, for verification: evidence must not be windowed away. The model
; read whole pages, so the checker must see them too, or it rejects correct
; answers as "unsupported" (seen: "2012" at character 5229 of a Wikipedia page
; the agent read, refused because the checker saw only 4000 characters).
; The semantic (LLM) check shares context-verify-total between the steps, at
; least context-verify-chars each; prompts.py caps the total.
(= (verify-budget)
   (let* (($k (step-count))
          ($share (if (> $k 0) (/ (config-value context-verify-total) $k) 0)))
         (if (> $share (config-value context-verify-chars)) $share (config-value context-verify-chars))))

(= (all-steps-repr)
   (let $k (verify-budget)
        (repr (sort-atom (collapse (match &wm (step $n $t $i $o) (fresh-view $n $t $i $o $k)))))))

; the Python checks (layer 2) are code, not a prompt: they get every result whole
(= (all-steps-full)
   (repr (sort-atom (collapse (match &wm (step $n $t $i $o) ($n $t $i $o))))))

; only facts relevant to this goal (memory.metta ranks them), not the whole &kb
(= (facts-repr) (repr (relevant-facts (goal-text))))
(= (episodes-repr) (repr (similar-episodes (goal-text))))

; The tools the model is offered. delegate is shown only when (config delegate on)
; and never to a helper (it cannot start another one). Off by default: a helper
; re-plans and re-fetches everything, which made 40-turn goals slower, not faster.
(= (offer-delegate)
   (and (== (collapse (config-value delegate)) (on))
        (not (== (collapse (config-value agent-depth)) (1)))))   ; unset agent-depth = main

(= (prompt-tool-catalog)
   (if (offer-delegate)
       (tool-catalog)
       (let $all (tool-catalog)                        ; bind first: superpose does not evaluate
            (collapse (let $t (superpose $all)
                           (if (== (car-atom $t) delegate) (empty) $t))))))

; What the model reads: one line per tool (name [permission]: what it does) and
; under it an EXACT call to copy, (action NAME "example input"). With a bare
; (name "desc" level) list, models knew WHICH tool to use but often not how to
; write the call (seen: gpt-oss reasoned "Use calc tool." and sent nothing).
; read from &caps directly (not tool-option): context works without tools.metta
(= (tool-example $n)
   (let $x (collapse (match &caps (tool-setting $n example $e) $e))
        (if (== $x ()) none (car-atom $x))))
(= (tool-row $t) (let ($n $d $l) $t ($n $d $l (tool-example $n))))
(= (prompt-tool-rows) (map-atom (prompt-tool-catalog) $t (tool-row $t)))
(= (tools-text) (py-call (prompts.render_tools (prompt-tool-rows))))

; the tools the current task's skills name (skill-needs), offered ones only:
; shown inside the CURRENT TASK block, so the right tool is right there
(= (task-tool-rows $id)
   (let* (($offered (prompt-tool-rows))
          ($skills (skills-of-task $id))                ; bound first: superpose does not evaluate
          ($wanted (unique-atom (collapse (let $s (superpose $skills)
                                               (match &caps (skill-needs $s $x) $x))))))
         (collapse (let $r (superpose $offered)
                        (if (is-member (car-atom $r) $wanted) $r (empty))))))

; The planner sees ALL available skills (name + description) and short
; summaries of the best matches; it may pick any skill, matched or not.
(= (plan-request)
   (py-call (prompts.plan_prompt (goal-text) (tools-text) (repr (skill-catalog))
                                 (recommended-skills-text (goal-text))
                                 (tasks-repr) (steps-repr) (facts-repr) (episodes-repr)
                                 (py-call (session.summary)))))

; the current task and the FULL guides of the skills it uses (skills.metta)
(= (current-task-repr)
   (let $t (current-task)
        (if (== $t none)
            "none"
            (py-call (skill_files.render_task $t (match &wm (task $t $d $s) $d)
                                              (skill-views (skills-of-task $t))
                                              (config-value skill-guide-chars)
                                              (task-tool-rows $t))))))

; PROGRESS shows the turns used INCLUDING those of helpers (agent.metta turns-used),
; so the model paces itself by what is really left. Unset (context loaded
; without agent.metta, or inside a helper) → own turns only.
(= (prompt-turn)
   (let $h (collapse (config-value helper-turns-used))
        (if (and (== (collapse (config-value agent-depth)) (0)) (not (== $h ())))
            (+ (current-turn) (car-atom $h))
            (current-turn))))

(= (act-request)
   (py-call (prompts.act_prompt (goal-text) (tasks-repr) (current-task-repr) (steps-repr)
                                (tools-text) (facts-repr) (repr ((latest-final-feedback) (recovery-hints)))
                                (prompt-turn) (config-value max-iterations)
                                (py-call (session.summary)) (repr (skill-catalog))
                                (repr (note-list)))))

; Keep verification feedback visible even after task-done or other successful
; calls, which would otherwise replace the last-failure recovery hints.
(= (latest-final-feedback)
   (let $rejected (sort-atom (collapse (match &wm (step $n finish $a (error (verification-failed $p)))
                                              ((- 0 $n) $p))))
        (if (== $rejected ()) none
            (final-feedback (index-atom (car-atom $rejected) 1)))))

; size of what is sent each iteration (for measuring)
(= (context-chars) (py-call (toolrunner.length (act-request))))
