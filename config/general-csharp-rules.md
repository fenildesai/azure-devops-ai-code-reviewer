# General .NET & C# Coding Standards

## 1. Performance (CS-ASYNC-001)
- **Rule:** Always use `await` with asynchronous methods. 
- **Violation:** Flag any use of `.Result` or `.Wait()` which can cause thread deadlocks.

## 2. Security (CS-SEC-002)
- **Rule:** Never hardcode connection strings, API keys, passwords, or any sensitive tokens.
- **Violation:** Flag any plaintext secrets in the code. Verify that `IConfiguration`, Azure Key Vault, or similar secure configuration patterns are used instead.

## 3. Architecture (CS-DI-003)
- **Rule:** Ensure dependencies are injected via constructor injection.
- **Violation:** Flag instances where services are instantiated directly using `new` within business logic layers instead of being resolved from the DI container.

## 4. Error Handling (CS-ERR-004)
- **Rule:** Never swallow exceptions. 
- **Violation:** Flag empty `catch` blocks or `catch` blocks that only log the exception but do not rethrow or handle it appropriately.

## 5. SQL Best Practices (SQL-INJ-005)
- **Rule:** Prevent SQL injection.
- **Violation:** Flag raw string concatenation in SQL queries. Ensure parameterized queries (e.g., using Dapper parameters or Entity Framework LINQ) are used.
