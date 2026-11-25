; recovery.metta — Error Recovery Manager. Needs core/schema.metta.
;
;   (error-class X)            temporary | permanent
;   (retryable OUTCOME)        True for (error X) with a temporary X
;   (declare-alternative A B)  if tool A fails, B can do the same job
;   (recovery-hints)           what PeTTa tells the model after a failure
;   (learn-recoveries)         after a successful run: remember what fixed failures

!(import! &self "toolrunner.py")

!(set-config max-retries 3)        ; retries per tool call (temporary errors only)
!(set-config retry-backoff 0.5)    ; seconds before retry 1; doubles each retry
!(set-config llm-backoff 2)        ; seconds × attempt, for temporary LLM errors

; ---------------- classify ----------------
(= (error-class $e) (py-call (toolrunner.classify (repr $e))))

(= (retryable $out)
   (if (== (car-atom $out) error)
       (== (error-class (index-atom $out 1)) temporary)
       False))

(= (backoff $attempt)
   (py-call (toolrunner.backoff_sleep (* (config-value retry-backoff) (pow-math 2 (- $attempt 1))))))

; ---------------- alternatives ----------------
(= (declare-alternative $a $b)
   (let $r (add-atom &caps (alternative $a $b)) (alternative-declared $a $b)))

; only alternatives that are actually declared tools
(= (alternatives-for $t)
   (collapse (let $b (match &caps (alternative $t $x) $x)
                  (if (tool-known $b) $b (empty)))))

; fixes learned in earlier runs: ((CLASS HOW) ...)
(= (known-fixes $t)
   (collapse (match &kb (fact (fix (fails $t $cls) $how) $m) ($cls $how))))

; ---------------- hints for the model ----------------
(= (last-step)
   (let $n (step-count)
        (if (== $n 0)
            none
            (let $s (collapse (match &wm (step $n $t $i $o) ($t $i $o)))
                 (if (== $s ()) none (car-atom $s))))))

; none, or (last-failure TOOL INPUT ERROR (class C) (alternatives ..) (fixes ..))
(= (recovery-hints)
   (let $s (last-step)
        (if (== $s none)
            none
            (let* (($t (index-atom $s 0))
                   ($o (index-atom $s 2)))
                  (if (and (== (car-atom $o) error) (tool-known $t))
                      (let $e (index-atom $o 1)
                           (last-failure $t (index-atom $s 1) $e
                                         (class (error-class $e))
                                         (alternatives (alternatives-for $t))
                                         (fixes (known-fixes $t))))   ; tag ≠ function name
                      none)))))

; ---------------- learning from recovery ----------------
; earliest successful step of a DIFFERENT tool after step $n → tool, or none
; the first OTHER work tool (schema.metta) that succeeded within 3 steps after the failure
(= (first-success-after $n $t)
   (let $later (sort-atom (collapse (let $s (match &wm (step $m $t2 $i2 (ok $x)) ($m $t2))
                                         (if (and (and (> (index-atom $s 0) $n)
                                                       (<= (index-atom $s 0) (+ $n 3)))
                                                  (and (work-tool (index-atom $s 1))
                                                       (not (== (index-atom $s 1) $t))))
                                             $s (empty)))))
        (if (== $later ()) none (index-atom (car-atom $later) 1))))

; For each failed tool step that a later different tool made up for:
;   (fix (fails TOOL CLASS) (use OTHER))  — and retries that worked:
;   (fix (fails TOOL temporary) retry)
(= (learn-recoveries)
   (unique-atom
     (collapse
       (superpose
         ((let* (($f (match &wm (step $n1 $t1 $i1 (error $e1)) ($n1 $t1 $e1)))
                 ($tool (index-atom $f 1))
                 ($ok (tool-known $tool))
                 ($alt (if $ok (first-success-after (index-atom $f 0) $tool) none)))
                (if (== $alt none)
                    (empty)
                    (let* (($cls (error-class (index-atom $f 2)))
                           ($r (learn-fact (fix (fails $tool $cls) (use $alt)) 0.7 agent)))   ; gated
                          (fails $tool $cls (use $alt)))))
          (let* (($rt (match &wm (retried $t2 $i2 $k) ($t2 $i2)))
                 ($tool2 (index-atom $rt 0))
                 ($in2 (index-atom $rt 1)))
                (if (== (collapse (match &wm (step $m $tool2 $in2 (ok $x)) $m)) ())
                    (empty)
                    (let $r (learn-fact (fix (fails $tool2 temporary) retry) 0.7 agent)   ; gated
                         (fails $tool2 temporary retry)))))))))
