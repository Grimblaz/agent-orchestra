# Architecture Rules

This document defines the architectural constraints for the Order Service microservice. All agents and developers must follow these rules.

These rules are provided as an example baseline for a Spring Boot microservice; when adopting this template, adjust them to match your project's actual architecture and constraints.

## Layer Architecture

### Layer Definitions

| Layer | Responsibility | Allowed Dependencies |
|-------|---------------|---------------------|
| **Controller** | HTTP handling, request/response mapping | Service, DTO, Mapper |
| **Service** | Business logic, orchestration | Repository, Entity, Client, DTO |
| **Repository** | Data persistence operations | Entity only |
| **Client** | External service communication | DTO (external) |
| **DTO** | Data transfer objects | None (POJOs) |
| **Entity** | Domain model, persistence | None (POJOs) |
| **Mapper** | Object transformation | DTO, Entity |

### Layer Diagram

```text
                    ┌──────────────┐
                    │  Controller  │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
          ┌─────────│   Service    │─────────┐
          │         └──────┬───────┘         │
          │                │                 │
    ┌──────▼───────┐ ┌──────▼───────┐ ┌───────▼──────┐
    │    Client    │ │  Repository  │ │    Mapper    │
    └──────────────┘ └──────────────┘ └──────────────┘
```

## Dependency Rules

### ✅ ALLOWED

```java
// Controller → Service
@RestController
@RequiredArgsConstructor
public class OrderController {
    private final OrderService orderService;  // ✅ OK
}

// Service → Repository
@Service
@RequiredArgsConstructor
public class OrderService {
    private final OrderRepository orderRepository;  // ✅ OK
    private final PaymentClient paymentClient;      // ✅ OK
}

// Service → Service (same layer)
@Service
public class OrderService {
    private final InventoryService inventoryService;  // ✅ OK
}
```

### ❌ PROHIBITED

```java
// Controller → Repository (bypassing Service)
@RestController
public class OrderController {
    private final OrderRepository orderRepository;  // ❌ VIOLATION
}

// Repository → Service (reverse dependency)
@Repository
public class OrderRepository {
    private final OrderService orderService;  // ❌ VIOLATION
}

// Circular dependencies
@Service
public class OrderService {
    private final PaymentService paymentService;  // ❌ if PaymentService depends on OrderService
}
```

## Package Access Rules

### Internal vs External

```text
com.example.orderservice/
├── controller/          # @RestController classes only
│   └── internal/        # Internal endpoints (not exposed)
├── service/
│   ├── impl/           # Service implementations
│   └── internal/       # Internal services (not injected in controllers)
├── repository/         # Spring Data interfaces only
├── entity/             # @Entity classes only
└── dto/
    ├── request/        # Incoming DTOs
    └── response/       # Outgoing DTOs
```

### Visibility

- Controllers: `public` (exposed via REST)
- Services: `public` interface, `package-private` implementation when possible
- Repositories: `public` (Spring Data requirement)
- Entities: `public` (JPA requirement)
- DTOs: `public` (serialization requirement)

## API Design Rules

### REST Conventions

| Operation | HTTP Method | Path Pattern | Response Code |
|-----------|------------|--------------|---------------|
| List | GET | `/orders` | 200 |
| Get | GET | `/orders/{id}` | 200, 404 |
| Create | POST | `/orders` | 201 |
| Update | PUT | `/orders/{id}` | 200, 404 |
| Partial Update | PATCH | `/orders/{id}` | 200, 404 |
| Delete | DELETE | `/orders/{id}` | 204, 404 |

### Request/Response Patterns

```java
// Request DTO
public record CreateOrderRequest(
    @NotNull Long customerId,
    @NotEmpty List<OrderItemRequest> items
) {}

// Response DTO
public record OrderResponse(
    Long id,
    Long customerId,
    OrderStatus status,
    List<OrderItemResponse> items,
    Instant createdAt
) {}

// Error Response (RFC 7807)
// Use Spring's ProblemDetail
```

## Data Layer Rules

### Entity Design

```java
@Entity
@Table(name = "orders")
public class Order {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)  // ✅ Explicit strategy
    private Long id;
    
    @Column(nullable = false)  // ✅ Explicit constraints
    private Long customerId;
    
    @Enumerated(EnumType.STRING)  // ✅ String for enums
    private OrderStatus status;
    
    @OneToMany(mappedBy = "order", cascade = CascadeType.ALL)
    private List<OrderItem> items;
}
```

### Repository Design

```java
public interface OrderRepository extends JpaRepository<Order, Long> {
    // Prefer derived queries for simple cases
    List<Order> findByCustomerId(Long customerId);
    
    // Use @Query for complex queries
    @Query("SELECT o FROM Order o WHERE o.status = :status AND o.createdAt > :since")
    List<Order> findRecentByStatus(@Param("status") OrderStatus status, 
                                    @Param("since") Instant since);
}
```

## Testing Rules

### Test Classification

| Type | Scope | Dependencies | Location |
|------|-------|-------------|----------|
| Unit | Single class | Mocked | `src/test/java` |
| Integration | Multiple classes | Real (TestContainers) | `src/test/java` |
| API | Full stack | Embedded server | `src/test/java` |

### Coverage Requirements

- **Minimum**: 80% line coverage
- **Services**: 90% branch coverage
- **Critical paths**: 100% coverage

### Test Naming

```java
@Test
void shouldCreateOrder_whenValidRequest() { }

@Test
void shouldThrowException_whenCustomerNotFound() { }

@Test
void shouldReturnEmpty_whenNoOrdersExist() { }
```

## Security Rules

### Authentication

- All endpoints require authentication except `/actuator/health`
- Use JWT tokens via Spring Security
- Validate token signature and expiration

### Authorization

```java
@PreAuthorize("hasRole('ADMIN')")
public void deleteOrder(Long id) { }

@PreAuthorize("hasRole('USER') and #customerId == authentication.principal.customerId")
public List<Order> getOrdersByCustomer(Long customerId) { }
```

## Observability Rules

### Logging

```java
// Use SLF4J with structured logging
private static final Logger log = LoggerFactory.getLogger(OrderService.class);

public Order createOrder(CreateOrderRequest request) {
    log.info("Creating order for customer={}", request.customerId());
    // ...
    log.info("Order created: orderId={}, itemCount={}", order.getId(), order.getItems().size());
}
```

### Metrics

- Expose via Micrometer/Prometheus
- Track: request count, latency, error rate
- Custom metrics for business events

### Tracing

- Use Spring Cloud Sleuth / Micrometer Tracing
- Propagate trace IDs across service calls
- Log trace IDs in all log messages

<!--
## Migration Safety

When your project includes data migration (merging records from multiple sources, syncing across
devices, or migrating between storage backends), security-sensitive fields require special handling.
Full-record overwrite operations (`repository.save()`, `entityManager.merge()`) can silently replace
a non-null security value with null when the source record lacks that field.

### Security-Sensitive Fields

Enumerate security-sensitive fields per data store. These fields must never be silently overwritten
by null or absent source values during migration.

| Field | Data Store | Merge Strategy |
|-------|-----------|----------------|
| `parentPinHash` | JPA `UserProfile` entity | Preserve non-null target; first-device PIN becomes family PIN |
| `sessionToken` | (example) | Preserve non-null target |
| `permissionFlags` | (example) | Preserve non-null target; per-profile independent |

Customize this table for your project's actual security-sensitive fields.

### Overwrite Protection Pattern

Instead of full-record overwrite:

```java
// UNSAFE — saves entire entity including security fields
userProfileRepository.save(localProfile);
```

Use field-level updates that preserve security values:

```java
// SAFE — update only data fields, preserve security columns
@Modifying
@Query("UPDATE UserProfile u SET u.displayName = :name, u.avatarUrl = :avatar "
     + "WHERE u.id = :id")
void updateDataFields(@Param("id") Long id, @Param("name") String name,
                      @Param("avatar") String avatar);

// Or use @DynamicUpdate on the entity and null-check security fields before save
```

Alternative: `@DynamicUpdate` with null-check fill (mirrors Node.js/Python "preserve non-null, fill null from source" strategy):

```java
// SAFE — @DynamicUpdate with null-check fill
@Transactional
public void migrateSafe(UserProfile source, UserProfile target) {
    target.setDisplayName(source.getDisplayName());
    target.setAvatarUrl(source.getAvatarUrl());
    // Preserve non-null security fields; fill only if target is null
    if (target.getParentPinHash() == null) {
        target.setParentPinHash(source.getParentPinHash());
    }
    if (target.getSessionToken() == null) {
        target.setSessionToken(source.getSessionToken());
    }
    if (target.getPermissionFlags() == null) {
        target.setPermissionFlags(source.getPermissionFlags());
    }
    repository.save(target); // @DynamicUpdate generates minimal SQL
}
```
-->
