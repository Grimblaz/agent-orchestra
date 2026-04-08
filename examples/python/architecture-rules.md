# Architecture Rules

This document defines the architectural constraints for the Inventory Service. All agents and developers must follow these rules.

These rules are provided as an example baseline for a Python / FastAPI project; when adopting this template, adjust them to match your project's actual architecture and constraints.

## Layer Architecture

### Layer Definitions

| Layer | Responsibility | Allowed Dependencies |
|-------|---------------|---------------------|
| **Routers** | HTTP path operations, request validation | Service, Schema, Depends() |
| **Services** | Business logic, orchestration | Repository, Schema, errors/ |
| **Repositories** | SQLAlchemy queries, data mapping | Model (ORM) |
| **Models** | SQLAlchemy ORM table definitions | None |
| **Schemas** | Pydantic request/response models | None |
| **Dependencies** | FastAPI Depends() providers | Session, Settings |

### Layer Diagram

```text
                    ┌──────────────┐
                    │    Routers   │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │   Services   │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │ Repositories │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │    Models    │
                    └──────────────┘
```

## Dependency Rules

### ✅ ALLOWED

```python
# Routers → Service (via Depends)
# app/routers/inventory_router.py
from fastapi import APIRouter, Depends
from app.services.inventory_service import InventoryService
from app.dependencies.services import get_inventory_service

router = APIRouter(prefix="/inventory", tags=["inventory"])

@router.post("/", status_code=201)
async def create_product(
    body: CreateProductSchema,
    service: InventoryService = Depends(get_inventory_service),  # ✅ injected
) -> ProductSchema:
    return await service.create_product(body)

# Service → Repository
# app/services/inventory_service.py
class InventoryService:
    def __init__(self, repository: InventoryRepository) -> None:  # ✅ constructor injection
        self._repository = repository

    async def get_product(self, product_id: int) -> ProductSchema:
        product = await self._repository.find_by_id(product_id)
        if product is None:
            raise_not_found("Product", product_id)  # ✅ helper from errors/
        return ProductSchema.model_validate(product)

# Repository → Model (ORM)
# app/repositories/inventory_repository.py
class InventoryRepository:
    def __init__(self, session: AsyncSession) -> None:  # ✅ session injected
        self._session = session

    async def find_by_id(self, product_id: int) -> Product | None:
        result = await self._session.get(Product, product_id)  # ✅ OK
        return result

# Service → Service (same layer, for orchestration)
class StockAdjustmentService:
    def __init__(
        self,
        inventory_service: InventoryService,   # ✅ OK
        audit_service: AuditService,           # ✅ OK
    ) -> None: ...
```

### ❌ PROHIBITED

```python
# Router → Repository (bypassing Service)
@router.get("/{product_id}")
async def get_product(
    product_id: int,
    repo: InventoryRepository = Depends(get_inventory_repository),  # ❌ VIOLATION
) -> ProductSchema: ...

# Repository → Service (reverse dependency)
class InventoryRepository:
    def __init__(self, service: InventoryService) -> None:  # ❌ VIOLATION
        self._service = service

# Missing type hints
def create_product(body):  # ❌ VIOLATION — all signatures must be typed
    return ...

# Raw SQL string interpolation
await session.execute(
    text(f"SELECT * FROM products WHERE id = {product_id}")  # ❌ SQL injection risk
)

# Importing session directly in a service
from app.dependencies.db import async_session_factory  # ❌ use Depends() instead

# Using implicit Any
def process(data):  # ❌ mypy strict will reject untyped params
    return data
```

## File & Naming Rules

```text
app/
├── routers/
│   └── inventory_router.py          # *_router.py — one file per resource group
├── services/
│   └── inventory_service.py         # *_service.py — class + module share name
├── repositories/
│   └── inventory_repository.py      # *_repository.py
├── models/
│   └── inventory.py                 # domain name — SQLAlchemy ORM class(es)
├── schemas/
│   └── inventory_schema.py          # *_schema.py — Pydantic v2 models
├── errors/
│   └── http_errors.py               # raise_not_found(), raise_conflict(), etc.
└── dependencies/
    ├── db.py                         # get_session() Depends provider
    └── services.py                   # get_inventory_service() Depends provider
tests/
├── unit/
│   └── test_inventory_service.py    # test_*.py — mirrors app/services/
├── integration/
│   └── test_inventory_repository.py # test_*.py — mirrors app/repositories/
└── routers/
    └── test_inventory_router.py     # test_*.py — mirrors app/routers/
```

## API Design Rules

### REST Conventions

| Operation | HTTP Method | Path Pattern | Response Code |
|-----------|------------|--------------|---------------|
| List | GET | `/inventory` | 200 |
| Get | GET | `/inventory/{id}` | 200, 404 |
| Create | POST | `/inventory` | 201 |
| Update | PUT | `/inventory/{id}` | 200, 404 |
| Partial Update | PATCH | `/inventory/{id}` | 200, 404 |
| Delete | DELETE | `/inventory/{id}` | 204, 404 |

### Request / Response Shapes

```python
from pydantic import BaseModel, ConfigDict, Field

# Request schema
class CreateProductSchema(BaseModel):
    sku: str = Field(..., min_length=1, max_length=50)
    name: str = Field(..., min_length=1)
    quantity: int = Field(..., ge=0)
    warehouse_id: int

# Response schema (ORM mode)
class ProductSchema(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    sku: str
    name: str
    quantity: int
    warehouse_id: int
    created_at: datetime

# Error response (raised as HTTPException)
# HTTP 404
# { "detail": { "code": "PRODUCT_NOT_FOUND", "message": "Product 42 not found" } }
```

## Error Handling Rules

```python
# ✅ Define reusable helpers in app/errors/http_errors.py
from fastapi import HTTPException

def raise_not_found(resource: str, resource_id: int | str) -> None:
    raise HTTPException(
        status_code=404,
        detail={
            "code": f"{resource.upper()}_NOT_FOUND",
            "message": f"{resource} {resource_id} not found",
        },
    )

def raise_conflict(resource: str, field: str, value: str) -> None:
    raise HTTPException(
        status_code=409,
        detail={
            "code": f"{resource.upper()}_CONFLICT",
            "message": f"{resource} with {field}='{value}' already exists",
        },
    )

# ✅ Use helpers in services
async def get_product(self, product_id: int) -> ProductSchema:
    product = await self._repository.find_by_id(product_id)
    if product is None:
        raise_not_found("Product", product_id)  # ✅
    return ProductSchema.model_validate(product)
```

## Testing Rules

### Test Classification

| Type | Scope | Tool | What to mock |
|------|-------|------|--------------|
| Unit | Single service class | pytest | Repository (MagicMock / AsyncMock) |
| Integration | Repository + real DB | pytest | Test database (SQLite or Docker PG) |
| Router | Full HTTP stack | pytest + httpx | Service (AsyncMock) |

### Coverage Requirements

- **Minimum**: 80% line coverage across the project
- **Services**: 90% branch coverage
- **Critical paths** (stock mutations, auth): 100% coverage

### Unit Tests (Services)

```python
# tests/unit/test_inventory_service.py
import pytest
from unittest.mock import AsyncMock
from app.services.inventory_service import InventoryService
from app.errors.http_errors import raise_not_found

@pytest.fixture
def mock_repo() -> AsyncMock:
    return AsyncMock()

@pytest.fixture
def service(mock_repo: AsyncMock) -> InventoryService:
    return InventoryService(repository=mock_repo)

async def test_get_product_returns_product_when_found(
    service: InventoryService,
    mock_repo: AsyncMock,
) -> None:
    mock_repo.find_by_id.return_value = FakeProduct(id=1, sku="ABC-001")
    result = await service.get_product(1)
    assert result.sku == "ABC-001"

async def test_get_product_raises_404_when_not_found(
    service: InventoryService,
    mock_repo: AsyncMock,
) -> None:
    mock_repo.find_by_id.return_value = None
    with pytest.raises(HTTPException) as exc_info:
        await service.get_product(99)
    assert exc_info.value.status_code == 404
```

### Router Tests (FastAPI TestClient)

```python
# tests/routers/test_inventory_router.py
import pytest
from httpx import AsyncClient, ASGITransport
from unittest.mock import AsyncMock, patch
from app.main import create_app

@pytest.fixture
def mock_service() -> AsyncMock:
    return AsyncMock()

async def test_create_product_returns_201(mock_service: AsyncMock) -> None:
    mock_service.create_product.return_value = ProductSchema(
        id=1, sku="XYZ-99", name="Widget", quantity=10, warehouse_id=2,
        created_at=datetime.utcnow(),
    )
    app = create_app(inventory_service=mock_service)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/inventory/", json={
            "sku": "XYZ-99", "name": "Widget", "quantity": 10, "warehouse_id": 2,
        })
    assert response.status_code == 201
    assert response.json()["sku"] == "XYZ-99"
```

### Test Naming

```python
def test_get_product_returns_product_when_found(): ...
def test_get_product_raises_404_when_not_found(): ...
def test_adjust_stock_raises_conflict_when_quantity_below_zero(): ...
```

## Observability Rules

### Logging

```python
# Use structlog or the standard logging module with JSON formatting
import logging
logger = logging.getLogger(__name__)

# In services — log business events with context
logger.info("Product created", extra={"product_id": product.id, "sku": product.sku})

# Never log raw request bodies that may contain PII or secrets
```

### Metrics

- Expose `/metrics` via `prometheus-fastapi-instrumentator`
- Track: request count, request latency (p50/p95/p99), error rate
- Emit custom counters for significant business events (stock adjustments, etc.)

<!--
## Migration Safety

When your project includes data migration (merging records from multiple sources, syncing across
devices, or migrating between storage backends), security-sensitive fields require special handling.
Full-record overwrite operations (`session.merge()`, bulk `__dict__` update, dict unpacking) can silently replace
a non-null security value with null when the source record lacks that field.

### Security-Sensitive Fields

Enumerate security-sensitive fields per data store. These fields must never be silently overwritten
by null or absent source values during migration.

| Field | Data Store | Merge Strategy |
|-------|-----------|----------------|
| `parent_pin_hash` | SQLAlchemy `user_profiles` | Preserve non-null target; first-device PIN becomes family PIN |
| `session_token` | (example) | Preserve non-null target |
| `permission_flags` | (example) | Preserve non-null target; per-profile independent |

Customize this table for your project's actual security-sensitive fields.

### Overwrite Protection Pattern

Instead of full-record overwrite:

```python
# UNSAFE — replaces entire row including security columns
session.merge(UserProfile(**local_data))
```

Use explicit column updates that preserve security values:

```python
# SAFE — update only data columns, preserve security fields
target = session.get(UserProfile, user_id)
security_fields = {"parent_pin_hash", "session_token", "permission_flags"}
for key, value in local_data.items():
    if key not in security_fields:
        setattr(target, key, value)
    elif getattr(target, key) is None:
        setattr(target, key, value)  # only fill if target is null
session.commit()
```
-->
