; verify.metta — multi-layer verification before a final answer is accepted.
; Needs schema, llm, tools. The model claiming "done" is never enough.
;
;   (verify-answer ANSWER) → () when accepted, else a list of problems
;
; Layer 1 SYMBOLIC (PeTTa)    every plan task completed; answer not empty
; Layer 2 OBJECTIVE (Python)  your checks: fn(goal, answer, observations) → True/False
;                             or ["ok", ..] / ["error", "why"]
;                               !(declare-verifier my_checks.has_number)          every goal
;                               !(set-skill-verifier research my_checks.cites)    tasks using the skill
; Layer 3 SEMANTIC (LLM)      a SEPARATE call: do the observations support the answer?
;                             (config verify-semantic on|off). If the LLM can't be
;                             reached or replies nonsense → "unknown": not blocking.
; Layers run in order and stop at the first failing layer (saves LLM calls).
; The outcome of each layer is stored: (verification N LAYER RESULT) in &wm.

!(set-config verify-semantic on)

(= (declare-verifier $f) (let $r (add-atom &caps (verifier $f)) (verifier-declared $f)))

; A CONCLUSIVE verifier proves the answer on its own (e.g. the answer states the
; number calc returned). When one passes, the semantic layer — an extra LLM call
; that re-sends every step — is skipped.
(= (set-conclusive-verifier $s $f)
   (if (skill-known $s)
       (let $r (add-atom &caps (conclusive-verifier $s $f)) (verifier-declared $s conclusive $f))
       (error (unknown-skill $s))))

(= (conclusive-verifiers)
   (unique-atom (collapse (let $s (match &wm (task-skill $id $x) $x)
                               (match &caps (conclusive-verifier $s $f) $f)))))

(= (proven $answer)
   (let $fs (conclusive-verifiers)                 ; bind before superpose (gotcha 2)
        (not (== (collapse (let* (($f (superpose $fs))
                                  ($r (py-call (toolrunner.run_verifier $f (goal-text) $answer (all-steps-full)))))
                                 (if (== (car-atom $r) ok) yes (empty))))
                 ()))))

(= (set-skill-verifier $s $f)
   (if (skill-known $s)
       (let $r (add-atom &caps (skill-verifier $s $f)) (verifier-declared $s $f))
       (error (unknown-skill $s))))

; ---------------- layer 1: symbolic ----------------
; An open task has no tool results yet (a final answer closes the RUNNING task,
; agent.metta). Tell the model exactly what to run: the tools of the task's skills.
;   (t1 (run-first (calc)))    t1 uses skill math, which needs calc
(= (task-tool-hint $id)
   (let $tools (unique-atom (collapse (let $s (match &wm (task-skill $id $x) $x)
                                           (match &caps (skill-needs $s $t) $t))))
        ($id (run-first $tools))))

(= (unfinished-problem)
   (let* (($o (open-tasks))
          ($hints (map-atom $o $id (task-tool-hint $id))))   ; bind: data is not evaluated
         (unfinished $o "no tool results yet for these tasks: run the tools they need (run-first) and then send final; a task whose work needs no tool can be marked (task-done ID ...), several in ONE reply" $hints)))

; questions the user did not answer: the answer must not fill them in by guessing
(= (unanswered-questions) (collapse (match &wm (step $n ask-user $q (error $e)) $q)))

(= (guessing-problem $answer)
   (let $qs (unanswered-questions)
        (if (or (== $qs ()) (py-call (text.reports_blocked $answer)))
            (empty)
            (guessing-instead-of-asking (unanswered $qs)
              "the user did not answer: do not invent the value - say what is blocked and what you need from the user"))))

(= (symbolic-problems $answer)
   (collapse
     (superpose
       ((if (all-done) (empty) (unfinished-problem))
        (if (py-call (toolrunner.is_blank $answer)) empty-answer (empty))
        (guessing-problem $answer)))))

; ---------------- layer 2: objective ----------------
; global verifiers + verifiers of skills used by this run's tasks
(= (active-verifiers)
   (unique-atom
     (collapse
       (superpose
         ((match &caps (verifier $f) $f)
          (let $s (match &wm (task-skill $id $x) $x)
               (match &caps (skill-verifier $s $f2) $f2)))))))

(= (objective-problems $answer)
   (collapse (let* (($fs (active-verifiers))           ; bind before superpose (gotcha 2)
                    ($f (superpose $fs))
                    ($r (py-call (toolrunner.run_verifier $f (goal-text) $answer (all-steps-full)))))
                   (case $r
                         (((ok $x) (empty))
                          ; Python text is a Symbol → make it a real String (gotcha 14)
                          ((error $why) (check-failed $f (as-string $why))))))))

; ---------------- layer 3: semantic ----------------
; → pass | (unsupported "why") | unknown (verifier unreachable / unparseable) | skipped
; the model replies (verdict supported "why") or (verdict unsupported "why").
; ("fail" is avoided as a symbol: it is a core Prolog word under PeTTa.)
(= (semantic-verdict $answer)
   (if (== (config-value verify-semantic) on)
       (let $r (ask-llm (py-call (prompts.verify_system))
                        (py-call (prompts.verify_prompt (goal-text) (tasks-repr) (all-steps-repr) $answer)))
            (case $r
                  (((ok $text)
                      (let $v (parse-reply $text)
                           (case $v
                                 (((verdict supported $why) pass)
                                  ((verdict unsupported $why) (unsupported $why))
                                  ($other unknown)))))
                   ($err unknown))))
       skipped))

(= (is-unsupported $v) (if (is-expression $v) (== (car-atom $v) unsupported) False))

; ---------------- all layers ----------------
(= (verification-round) (+ 1 (size-atom (collapse (match &wm (verification $n symbolic $r) $n)))))

(= (note-layer $n $layer $result) (add-atom &wm (verification $n $layer $result)))

(= (verify-answer $answer)
   (let* (($n (verification-round))
          ($p1 (symbolic-problems $answer))
          ($r1 (note-layer $n symbolic (if (== $p1 ()) pass $p1))))
         (if (not (== $p1 ()))
             $p1
             (let* (($p2 (objective-problems $answer))
                    ($r2 (note-layer $n objective (if (== $p2 ()) pass $p2))))
                   (if (not (== $p2 ()))
                       $p2
                       (let* (($v (if (proven $answer) skipped-proven (semantic-verdict $answer)))
                              ($r3 (note-layer $n semantic $v)))
                             (if (is-unsupported $v)
                                 ((semantic (index-atom $v 1)))
                                 ())))))))
