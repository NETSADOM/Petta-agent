; Benchmark: cost of recall as long-term memory grows. Not part of the test suite.
!(import! &self ../core/agent)

(= (fill $i $n)
   (if (> $i $n) $n
       (let* (($c (py-call (str $i)))
              ($r (remember (fact-number $c topic-a value-b) bench 0.9))
              ($j (+ $i 1)))
             (fill $j $n))))

(= (bench $n)
   (let* (($f (fill 1 $n))
          ($t0 (current-time))
          ($r (relevant-facts "tell me about fact-number topic-a"))
          ($t1 (current-time))
          ($s (similar-episodes "tell me about fact-number topic-a"))
          ($t2 (current-time)))
         (println! (facts (fact-count) relevant-facts-ms (* 1000 (- $t1 $t0)) episodes-ms (* 1000 (- $t2 $t1))))))

!(bench 50)
!(bench 200)
!(bench 500)
