# Architecture Rules

This document defines the architectural constraints for the Task Manager API. All agents and developers must follow these rules.

These rules are provided as an example baseline for a Node.js / TypeScript Express project; when adopting this template, adjust them to match your project's actual architecture and constraints.

## Layer Architecture

### Layer Definitions

| Layer | Responsibility | Allowed Dependencies |
|-------|---------------|---------------------|
| **Routes** | Register endpoints, attach middleware | Controller, Middleware |
| **Controllers** | Parse request, call service, shape response | Service, DTO, AppError |
| **Services** | Business logic, orchestration | Repository, Model, AppError |
| **Repositories** | SQL queries, data mapping | Model (DB row → domain type) |
| **Models** | TypeScript interfaces / domain types | None |
| **DTOs** | Request/response shapes (Zod schemas) | None |
| **Middleware** | Cross-cutting concerns (auth, validation) | AppError |

### Layer Diagram

```text
                    ┌──────────────┐
                    │    Routes    │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │ Controllers  │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │   Services   │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │ Repositories │
                    └──────────────┘
```

## Dependency Rules

### ✅ ALLOWED

```typescript
// Routes → Controller
// src/routes/task.routes.ts
import { TaskController } from '../controllers/TaskController';

const router = Router();
router.post('/tasks', asyncHandler(taskController.create));  // ✅ OK

// Controller → Service
// src/controllers/TaskController.ts
export class TaskController {
  constructor(private readonly taskService: TaskService) {}  // ✅ constructor injection

  async create(req: Request, res: Response): Promise<void> {
    const task = await this.taskService.createTask(req.body);  // ✅ OK
    res.status(201).json(task);
  }
}

// Service → Repository
// src/services/TaskService.ts
export class TaskService {
  constructor(private readonly taskRepository: TaskRepository) {}  // ✅ OK

  async createTask(dto: CreateTaskDto): Promise<Task> {
    return this.taskRepository.insert(dto);  // ✅ OK
  }
}

// Service → Service (same layer, for orchestration)
export class TaskAssignmentService {
  constructor(
    private readonly taskService: TaskService,       // ✅ OK
    private readonly userService: UserService,       // ✅ OK
  ) {}
}
```

### ❌ PROHIBITED

```typescript
// Controller → Repository (bypassing Service)
export class TaskController {
  constructor(private readonly taskRepository: TaskRepository) {}  // ❌ VIOLATION
}

// Repository → Service (reverse dependency)
export class TaskRepository {
  constructor(private readonly taskService: TaskService) {}  // ❌ VIOLATION
}

// Using `any` type
async function getTask(id: any): Promise<any> {  // ❌ VIOLATION — strict: true, never any
  return db.query('SELECT * FROM tasks WHERE id = $1', [id]);
}

// Raw string interpolation in SQL
const result = await db.query(`SELECT * FROM tasks WHERE id = ${id}`);  // ❌ SQL injection risk

// Direct `import` of a sibling service (bypassing constructor injection)
// src/services/TaskService.ts
import { UserService } from './UserService';  // ❌ import the concrete class and construct it
const userService = new UserService();        // ❌ creates hidden coupling — inject instead
```

## File & Naming Rules

```text
src/
├── routes/
│   └── task.routes.ts          # *.routes.ts — one file per resource
├── controllers/
│   └── TaskController.ts       # *Controller.ts — PascalCase class
├── services/
│   └── TaskService.ts          # *Service.ts — PascalCase class
├── repositories/
│   └── TaskRepository.ts       # *Repository.ts — PascalCase class
├── models/
│   └── task.model.ts           # *.model.ts — interfaces / types only
├── dtos/
│   └── task.dto.ts             # *.dto.ts — Zod schemas + inferred types
├── errors/
│   └── AppError.ts             # base error class
└── middleware/
    ├── auth.middleware.ts       # *.middleware.ts
    └── errorHandler.ts
```

### Co-located Tests

Tests live next to the file they test:

```text
src/
├── services/
│   ├── TaskService.ts
│   └── TaskService.test.ts     # ✅ co-located unit test
├── repositories/
│   ├── TaskRepository.ts
│   └── TaskRepository.test.ts  # ✅ co-located integration test
└── controllers/
    ├── TaskController.ts
    └── TaskController.test.ts  # ✅ co-located supertest test
```

## API Design Rules

### REST Conventions

| Operation | HTTP Method | Path Pattern | Response Code |
|-----------|------------|--------------|---------------|
| List | GET | `/tasks` | 200 |
| Get | GET | `/tasks/:id` | 200, 404 |
| Create | POST | `/tasks` | 201 |
| Update | PUT | `/tasks/:id` | 200, 404 |
| Partial Update | PATCH | `/tasks/:id` | 200, 404 |
| Delete | DELETE | `/tasks/:id` | 204, 404 |

### Request / Response Shapes

```typescript
// Request DTO (validated with express-validator or Zod)
interface CreateTaskDto {
  title: string;        // required, non-empty
  description?: string;
  assigneeId?: number;
  dueDate?: string;     // ISO 8601
}

// Success response — single resource
// HTTP 201
{ "id": 42, "title": "...", "status": "open", "createdAt": "..." }

// Success response — collection
// HTTP 200
{ "data": [...], "meta": { "total": 100, "page": 1, "pageSize": 20 } }

// Error response
// HTTP 404
{ "error": { "code": "TASK_NOT_FOUND", "message": "Task 42 not found" } }
```

## Error Handling Rules

```typescript
// ✅ Define domain errors as AppError subclasses
// src/errors/AppError.ts
export class AppError extends Error {
  constructor(
    public readonly httpStatus: number,
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = 'AppError';
  }
}

export class NotFoundError extends AppError {
  constructor(resource: string, id: number | string) {
    super(404, `${resource.toUpperCase()}_NOT_FOUND`, `${resource} ${id} not found`);
  }
}

// ✅ Throw AppError in services
async getTask(id: number): Promise<Task> {
  const task = await this.taskRepository.findById(id);
  if (!task) throw new NotFoundError('Task', id);
  return task;
}

// ✅ Use asyncHandler wrapper to forward errors to Express
// src/middleware/asyncHandler.ts
export const asyncHandler =
  (fn: RequestHandler): RequestHandler =>
  (req, res, next) =>
    Promise.resolve(fn(req, res, next)).catch(next);
```

## Testing Rules

### Test Classification

| Type | Scope | Tool | What to mock |
|------|-------|------|--------------|
| Unit | Single service class | Jest | Repository (jest.fn()) |
| Integration | Repository + real DB | Jest | Test database (Docker) |
| Controller/Route | Full HTTP stack | Jest + Supertest | Service (jest.fn()) |

### Coverage Requirements

- **Minimum**: 80% line coverage across the project
- **Services**: 90% branch coverage
- **Critical paths** (auth, payment, data mutations): 100% coverage

### Unit Tests (Services)

```typescript
// TaskService.test.ts
describe('TaskService', () => {
  let taskService: TaskService;
  let mockRepo: jest.Mocked<TaskRepository>;

  beforeEach(() => {
    mockRepo = {
      findById: jest.fn(),
      insert: jest.fn(),
    } as jest.Mocked<TaskRepository>;
    taskService = new TaskService(mockRepo);
  });

  it('should return task when found', async () => {
    mockRepo.findById.mockResolvedValue({ id: 1, title: 'Fix bug' });
    const result = await taskService.getTask(1);
    expect(result.title).toBe('Fix bug');
  });

  it('should throw NotFoundError when task does not exist', async () => {
    mockRepo.findById.mockResolvedValue(null);
    await expect(taskService.getTask(99)).rejects.toThrow(NotFoundError);
  });
});
```

### Controller / Route Tests (Supertest)

```typescript
// TaskController.test.ts
import request from 'supertest';
import { buildApp } from '../app';

describe('POST /tasks', () => {
  it('returns 201 with created task', async () => {
    const app = buildApp({ taskService: mockTaskService });
    const res = await request(app)
      .post('/tasks')
      .send({ title: 'New task' });
    expect(res.status).toBe(201);
    expect(res.body.title).toBe('New task');
  });
});
```

### Test Naming

```typescript
it('should create task when request is valid', ...);
it('should return 404 when task does not exist', ...);
it('should throw ValidationError when title is empty', ...);
```

## Observability Rules

### Logging

```typescript
// Use a structured logger (e.g., pino or winston)
// src/config/logger.ts
import pino from 'pino';
export const logger = pino({ level: process.env.LOG_LEVEL ?? 'info' });

// In services — log business events with context
logger.info({ taskId: task.id, assigneeId }, 'Task assigned');

// Never log raw request bodies that may contain PII
```

### Error Logging

```typescript
// src/middleware/errorHandler.ts
app.use((err: Error, req: Request, res: Response, _next: NextFunction) => {
  if (err instanceof AppError) {
    logger.warn({ code: err.code, path: req.path }, err.message);
    return res.status(err.httpStatus).json({ error: { code: err.code, message: err.message } });
  }
  logger.error({ err }, 'Unhandled error');
  res.status(500).json({ error: { code: 'INTERNAL_ERROR', message: 'An unexpected error occurred' } });
});
```

## Code Review Pitfalls

Rules for Code-Critic prosecution passes. These pitfalls are specific to JS/TS and are commonly masked by TypeScript's structural type system or mock-based test patterns.

### Prototype-Chain Preservation

Object spread (`{...obj}`) and `Object.assign({}, obj)` copy only own enumerable properties. When `obj` is a class instance, every method defined on the prototype chain becomes `undefined` on the copy. TypeScript's structural type system does not flag this because the interface is satisfied structurally. Mock-based tests also mask it because mocks define methods directly on the object.

#### ❌ PROHIBITED

```typescript
// Wrapper/proxy/decorator that strips the prototype chain
function wrapWithTracking(repo: TaskRepository): TaskRepository {
  const tracked = { ...repo };           // ❌ Methods from prototype are lost
  // or: const tracked = Object.assign({}, repo);  // ❌ Same problem
  return tracked;
}
```

#### ✅ SAFE

```typescript
// Preserve the prototype chain when copying a class instance
function wrapWithTracking(repo: TaskRepository): TaskRepository {
  const tracked = Object.assign(
    Object.create(Object.getPrototypeOf(repo)),
    repo,
  );
  return tracked;
}
```

**Scope**: Applies when the source object is a class instance in a wrapper, proxy, decorator, or factory function. Plain-object spread (`{...plainObj}`) is not affected.

<!--
## Migration Safety

When your project includes data migration (merging records from multiple sources, syncing across
devices, or migrating between storage backends), security-sensitive fields require special handling.
Full-record overwrite operations (`setDoc`, `replaceOne`, spread assignment) can silently replace
a non-null security value with null when the source record lacks that field.

### Security-Sensitive Fields

Enumerate security-sensitive fields per data store. These fields must never be silently overwritten
by null or absent source values during migration.

| Field | Data Store | Merge Strategy |
|-------|-----------|----------------|
| `parentPinHash` | Firestore `users` | Preserve non-null target; first-device PIN becomes family PIN |
| `sessionToken` | (example) | Preserve non-null target |
| `permissionFlags` | (example) | Preserve non-null target; per-profile independent |

Customize this table for your project's actual security-sensitive fields.

### Overwrite Protection Pattern

Instead of full-record overwrite:

```typescript
// UNSAFE — overwrites security fields with source values (including null)
await setDoc(doc(db, 'users', userId), localProfile);
```

Use field-level merge that preserves security values:

```typescript
// SAFE — read target security fields, merge explicitly
const targetSnap = await getDoc(doc(db, 'users', userId));
const targetData = targetSnap.exists() ? targetSnap.data() : {};

const {
  parentPinHash,
  sessionToken,
  permissionFlags,
  ...dataFields
} = localProfile;
const merged = {
  ...dataFields,
  parentPinHash: targetData.parentPinHash ?? parentPinHash,
  sessionToken: targetData.sessionToken ?? sessionToken,
  permissionFlags: targetData.permissionFlags ?? permissionFlags,
};
await setDoc(doc(db, 'users', userId), merged);
```
-->
