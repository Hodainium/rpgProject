Based on `specs/$ARGUMENTS.md`, write or update a Locust test in `load-test/locustfile.py` against `Rpg.GameServerApi`.
- Only exercise endpoints that exist in `src/Rpg.GameServerApi/`. Read the code first.
- Exercise Redis lock contention on `/api/v1/battle/verify`, e.g. several users submitting the same battle ID, and assert that exactly one submission succeeds.
- Locust only sees HTTP. Report p50/p95/p99 latency and error rates from Locust.
  Take queue depth, lock contention and verification failures from the server's Prometheus metrics (`http://localhost:9090`), not from Locust.
- Document the run command (users, spawn rate, host) at the top of the file.
- Before reporting, invoke the built-in `code-review` skill (Skill tool, level `high`) on the locustfile diff. Fix
  confirmed findings, and say in the summary what it found. A load test with a broken assertion can pass while proving nothing.
