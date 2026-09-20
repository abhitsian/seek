# Seek

Use the `typesafe-ai` skill (plugin `typesafe@typesafe-ai`) for any work on the TypeSafe/Jev integration: `Sources/Jev.swift`, `Sources/Planner.swift` (`JevPlanner`) and `Sources/Rank.swift` (`JevRank`). Read the live docs it points to (https://docs.typesafe.ai/llms.txt) before changing a request, and test request shapes against `Tools/mock_jev.py`, which rejects anything that breaks the documented schema.

A TypeSafe key is optional. Without one Seek reads searches with Apple Intelligence (`Sources/AppleReader.swift`), and without that with word lists. The key lives in `~/Library/Application Support/Seek/typesafe-key`; never print it or copy it elsewhere.
