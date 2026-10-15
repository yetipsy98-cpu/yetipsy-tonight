# Owner reset regression requirement

Every application, database, or migration change must run the reset regression
test (`node tests/reset_safeupdate_hotfix.test.cjs`) and the full test suite
before it is merged or deployed.

The reset regression must keep the following guarantees:

- The second confirmation is transactional: an error leaves business records
  intact and reports the database error for diagnosis.
- Resumable Auth and Storage cleanup must be tested separately from the
  transactional database reset; failed external cleanup must stay retryable.
- Every foreign-key child of a table cleared by the `records` scope is included
  in the same `TRUNCATE`. Review live foreign keys whenever a new order-linked
  or transaction table is added.
- Reset scope and safety guards remain covered by tests; never validate against
  production by executing a real reset.

GitHub Actions runs all `tests/*.test.cjs` on pushes to `main` and the reset
maintenance branch, as well as pull requests targeting `main`.
