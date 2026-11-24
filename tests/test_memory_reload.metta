; Fresh process: memory learned in test_memory survives, strings stay strings.

!(import! &self ../core/agent)

!(test (load-space &kb "data/test_memory_kb.metta") 3)
!(test (recall (boiling-point water $x)) (((boiling-point water 100) 0.99)))
; recall still ranks after reload (preferences always come first, by design)
!(test (relevant-facts "boiling water")
       (((preference user answer-style short) 0.9) ((boiling-point water 100) 0.99)))
