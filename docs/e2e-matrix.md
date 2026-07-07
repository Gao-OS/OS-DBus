# OS-DBus E2E Matrix

| ID | Group | Gate | Scenario | Actors | Backends | Expected |
| --- | --- | --- | --- | --- | --- | --- |
| E2E-001 | hello | smoke | client can connect and call Hello | ExDBus | reference, gao_bus | unique name starts with :1. |
| E2E-002 | bus | smoke | ListNames includes org.freedesktop.DBus | ExDBus | reference, gao_bus | name present |
| E2E-003 | names | smoke | RequestName returns primary owner | ExDBus | reference, gao_bus | primary owner |
| E2E-004 | names | smoke | ReleaseName removes owner | ExDBus | reference, gao_bus | name not owned |
| E2E-005 | methods | release | ExDBus calls GLib Echo | ExDBus, GLib-fixture | reference, gao_bus verified (2026-07-07) — gap fixed: bare AUTH now gets `REJECTED <mechanisms>`; EXTERNAL supports Linux bare-DATA transport-credential flow; NameAcquired/NameLost unicast signals emitted | returns same string |
| E2E-006 | methods | release | busctl calls Elixir Echo | busctl, Elixir-service | reference, gao_bus known_gap — unverified, busctl unavailable locally | returns same string |
| E2E-007 | methods | release | gdbus calls Elixir Add | gdbus, Elixir-service | reference, gao_bus verified (2026-07-07) — SASL mechanism-discovery gap fixed | returns integer sum |
| E2E-008 | errors | release | unknown method returns D-Bus error | ExDBus, service | reference, gao_bus verified | UnknownMethod |
| E2E-009 | errors | release | GLib AlwaysFail propagates error | ExDBus, GLib-fixture | reference, gao_bus verified (2026-07-07) — inherited E2E-005 auth/name-signal gaps fixed, including Linux bare-DATA EXTERNAL flow | Failed |
| E2E-010 | signals | release | AddMatch receives matching signal | ExDBus, GLib-fixture | reference, gao_bus verified (2026-07-07) — inherited E2E-005 auth/name-signal gaps fixed, including Linux bare-DATA EXTERNAL flow | signal received |
| E2E-011 | signals | release | unmatched signal is not delivered | ExDBus, GLib-fixture | reference, gao_bus verified (2026-07-07) — inherited E2E-005 auth/name-signal gaps fixed, including Linux bare-DATA EXTERNAL flow | no signal |
| E2E-012 | introspection | compat | busctl introspects Elixir service | busctl, Elixir-service | reference, gao_bus known_gap — unverified, busctl unavailable locally | XML contains interface |
| E2E-013 | properties | compat | gdbus Get property from GLib fixture | gdbus, GLib-fixture | reference, gao_bus known_gap | CurrentValue returned |
| E2E-014 | properties | compat | gdbus Set property on GLib fixture | gdbus, GLib-fixture | reference, gao_bus known_gap | value changed |
| E2E-015 | concurrency | stress | concurrent calls demux correctly | ExDBus, GLib-fixture | reference, gao_bus known_gap | all replies match serial |
| E2E-016 | failure | release | service disconnect cleans owned name | ExDBus, GLib-fixture | reference, gao_bus known_gap | NameOwnerChanged emitted |
| E2E-017 | failure | release | client disconnect does not crash bus | ExDBus | reference, gao_bus known_gap | bus remains responsive |
| E2E-018 | routing | release | method call to missing destination returns error | ExDBus | reference, gao_bus known_gap | ServiceUnknown |
| E2E-019 | bus | release | GetNameOwner works after RequestName | ExDBus | reference, gao_bus known_gap | owner unique name |
| E2E-020 | bus | release | NameHasOwner reflects ownership | ExDBus | reference, gao_bus known_gap | true/false transitions |
