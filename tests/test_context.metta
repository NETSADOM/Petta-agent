; Context manager tests: windowing, clipping, summaries, and measured prompt size.

!(import! &self ../core/agent)
!(import! &self "fake_tools.py")
!(declare-tool upper "uppercase" safe fake_tools.upper)
!(declare-tool flaky "fails" safe fake_tools.always_fails)
!(set-goal "a long task")

; 30 steps, every 5th one failing, each with a 1000-character observation
(= (fill $i)
   (if (> $i 30) done
       (let* (($big (py-call (fake_tools.big_text $i)))
              ($r (if (== (% $i 5) 0)
                      (record-step flaky "x" (error "service unavailable"))
                      (record-step upper "x" (ok $big))))
              ($j (+ $i 1)))
             (fill $j))))
!(fill 1)

; ---------------- window ----------------
!(test (py-call (operator.contains (steps-repr) "(earlier-steps 22 ok 18 failed 4 (failed-tools (flaky)))")) True)
!(test (py-call (operator.contains (steps-repr) "(23 upper")) True)     ; first step inside the window
; older steps stay visible in SHORT form, so early findings are not lost on long runs...
!(test (py-call (operator.contains (steps-repr) "(22 upper \"x\" (ok observation 22 lorem")) True)
!(test (py-call (operator.contains (steps-repr) "(15 flaky \"x\" (error \"service unavailable\"))")) True)
; ...the short form is short: 1000 characters → at most context-older-chars
!(test (< (py-call (toolrunner.length (steps-repr))) 12000) True)
; ...and beyond context-older-steps they are only counted
!(set-config context-older-steps 10)
!(test (py-call (operator.contains (steps-repr) "(12 upper")) False)
!(test (py-call (operator.contains (steps-repr) "(13 upper")) True)
!(test (py-call (operator.contains (steps-repr) "(earlier-steps 22 ok 18 failed 4 (failed-tools (flaky)))")) True)
!(set-config context-older-steps 20)
; observations are clipped for the prompt...
!(test (py-call (operator.contains (steps-repr) "...")) True)
; ...but stored in full in &wm
!(test (py-call (toolrunner.length (match &wm (step 1 upper $i (ok $v)) $v))) 1000)
; verification sees every step
!(test (py-call (operator.contains (all-steps-repr) "(1 upper")) True)

; ---------------- measured: prompt size with vs without the window ----------------
!(set-config context-steps 1000)
!(set-config context-obs-chars 100000)
!(let $full (context-chars)
      (let* (($a (set-config context-steps 8))
             ($b (set-config context-obs-chars 600))
             ($windowed (context-chars)))
            (let $p (py-call (fake_tools.record_size $full $windowed))
                 ; "full" is itself capped at prompts.STEPS_MAX (16 000 chars of history),
                 ; and the window keeps 20 older steps in short form: so < half, not < a third
                 (test (< $windowed (/ $full 2)) True))))

; small runs are untouched: no summary atom when everything fits
!(clear-wm)
!(set-goal "short")
!(record-step upper "x" (ok A))
!(test (py-call (operator.contains (steps-repr) "earlier-steps")) False)
