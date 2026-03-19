# Technical Debt Tracker

This document tracks known technical debt in the Order Service. Items are prioritized and should be addressed as part of regular development cycles.

## How to Use This Document

1. **Adding Debt**: When introducing known shortcuts or identifying issues, add an entry here
2. **Prioritizing**: Use the priority levels (Critical, High, Medium, Low)
3. **Linking**: Reference related issues/PRs when addressing debt
4. **Removing**: Delete entries when debt is fully resolved

## Priority Definitions

| Priority | Impact | Timeline |
|----------|--------|----------|
| 🔴 **Critical** | Production risk, security issue | Next sprint |
| 🟠 **High** | Performance impact, blocks features | Within 2 sprints |
| 🟡 **Medium** | Maintainability concern, code smell | Within quarter |
| 🟢 **Low** | Nice to have, minor improvement | When convenient |

---

## Active Technical Debt

### 🔴 Critical

#### [DEBT-001] Missing Input Validation on Bulk Operations

- **Location**: `OrderController.createBulkOrders()`
- **Description**: Bulk order endpoint accepts unbounded list size, potential DoS vector
- **Impact**: Could exhaust memory/DB connections with large payloads
- **Proposed Solution**: Add `@Size(max = 100)` validation, implement pagination for large imports
- **Added**: 2024-01-15
- **Owner**: @backend-team

---

### 🟠 High

#### [DEBT-002] N+1 Query in Order List Endpoint

- **Location**: `OrderService.getOrdersWithItems()`
- **Description**: Fetching orders with items causes N+1 queries due to lazy loading
- **Impact**: ~500ms latency on list of 50 orders
- **Proposed Solution**: Use `@EntityGraph` or `JOIN FETCH` query
- **Added**: 2024-01-10
- **Related**: #123

#### [DEBT-003] Hardcoded Payment Service URL

- **Location**: `PaymentClient`
- **Description**: Payment service URL hardcoded, should use service discovery
- **Impact**: Requires redeployment for environment changes
- **Proposed Solution**: Move to configuration, implement service discovery
- **Added**: 2024-01-08

---

### 🟡 Medium

#### [DEBT-004] Duplicate Validation Logic

- **Location**: `OrderService`, `OrderController`
- **Description**: Order validation duplicated between controller and service layers
- **Impact**: Maintenance burden, risk of drift
- **Proposed Solution**: Centralize in service layer, use `@Valid` only for syntax
- **Added**: 2024-01-05

#### [DEBT-005] Missing Retry Logic for External Calls

- **Location**: `PaymentClient`, `InventoryClient`
- **Description**: External HTTP calls have no retry mechanism
- **Impact**: Transient failures cause immediate order failures
- **Proposed Solution**: Add Resilience4j `@Retry` with exponential backoff
- **Added**: 2024-01-03

#### [DEBT-006] Test Data Builders Needed

- **Location**: `src/test/java`
- **Description**: Tests create entities manually, lots of duplication
- **Impact**: Tests are verbose, hard to maintain
- **Proposed Solution**: Create builder pattern test utilities
- **Added**: 2023-12-20

---

### 🟢 Low

#### [DEBT-007] Inconsistent Exception Messages

- **Location**: Various service classes
- **Description**: Exception messages don't follow consistent format
- **Impact**: Harder to parse in logs, inconsistent API error responses
- **Proposed Solution**: Create exception message templates
- **Added**: 2023-12-15

#### [DEBT-008] OpenAPI Descriptions Incomplete

- **Location**: Controller classes
- **Description**: Many endpoints missing `@Operation` descriptions
- **Impact**: Generated API docs are sparse
- **Proposed Solution**: Add comprehensive OpenAPI annotations
- **Added**: 2023-12-10

---

## Resolved Technical Debt

### ✅ [DEBT-000] Example Resolved Item

- **Location**: `SomeClass`
- **Description**: What was the issue
- **Resolution**: How it was fixed
- **Resolved**: 2024-01-20
- **PR**: #456

---

## Debt Metrics

| Priority | Count | Trend |
|----------|-------|-------|
| 🔴 Critical | 1 | ↓ (was 2) |
| 🟠 High | 2 | → |
| 🟡 Medium | 3 | ↑ (was 2) |
| 🟢 Low | 2 | → |
| **Total** | **8** | |

*Last updated: 2024-01-20*

---

## Notes for AI Agents

When working on this codebase:

1. **Check this document** before implementing features that touch noted areas
2. **Consider addressing debt** if it's in your implementation path
3. **Add new entries** when introducing intentional shortcuts
4. **Update entries** when partially addressing debt
5. **Link PRs** that resolve or reduce debt items

### Example Agent Workflow

```text
1. Read TECH-DEBT.md before starting implementation
2. If feature touches DEBT-002 area, consider fixing as part of work
3. If time-constrained and introducing shortcut, document here
4. In PR description, note: "Addresses DEBT-002" or "Introduces DEBT-009"
```
