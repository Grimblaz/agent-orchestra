# UI Testing Patterns Reference

Detailed patterns and examples for common UI testing scenarios.

## Form Testing

### Basic Form Submission
```javascript
it('should submit form with user input', async () => {
  const onSubmit = vi.fn()
  render(<ContactForm onSubmit={onSubmit} />)
  
  await userEvent.type(getByLabelText('Name'), 'Jane Doe')
  await userEvent.type(getByLabelText('Email'), 'jane@example.com')
  await userEvent.click(getByRole('button', { name: 'Send' }))
  
  expect(onSubmit).toHaveBeenCalledWith({
    name: 'Jane Doe',
    email: 'jane@example.com'
  })
})
```

### Form Validation
```javascript
it('should show validation error for invalid email', async () => {
  render(<ContactForm />)
  
  await userEvent.type(getByLabelText('Email'), 'invalid')
  await userEvent.click(getByRole('button', { name: 'Send' }))
  
  expect(getByRole('alert')).toHaveTextContent('Valid email required')
  expect(getByLabelText('Email')).toHaveAccessibleDescription(/valid email/i)
})
```

### Async Form Submission
```javascript
it('should show loading state during submission', async () => {
  server.use(
    rest.post('/api/contact', async (req, res, ctx) => {
      await delay(100)
      return res(ctx.json({ success: true }))
    })
  )
  
  render(<ContactForm />)
  await userEvent.click(getByRole('button', { name: 'Send' }))
  
  expect(getByRole('button', { name: 'Sending...' })).toBeDisabled()
  expect(await findByText('Message sent!')).toBeInTheDocument()
})
```

## List and Table Testing

### Testing List Rendering
```javascript
it('should render all items', () => {
  render(<UserList users={mockUsers} />)
  
  const listItems = getAllByRole('listitem')
  expect(listItems).toHaveLength(mockUsers.length)
  
  mockUsers.forEach(user => {
    expect(getByText(user.name)).toBeInTheDocument()
  })
})
```

### Testing Table Sorting
```javascript
it('should sort by column when header clicked', async () => {
  render(<DataTable data={mockData} />)
  
  await userEvent.click(getByRole('columnheader', { name: 'Name' }))
  
  const cells = getAllByRole('cell', { name: /name/i })
  const names = cells.map(cell => cell.textContent)
  
  expect(names).toEqual([...names].sort())
})
```

### Testing Pagination
```javascript
it('should navigate pages', async () => {
  render(<PaginatedList items={manyItems} pageSize={10} />)
  
  expect(getByText('Page 1 of 5')).toBeInTheDocument()
  expect(getAllByRole('listitem')).toHaveLength(10)
  
  await userEvent.click(getByRole('button', { name: 'Next page' }))
  
  expect(getByText('Page 2 of 5')).toBeInTheDocument()
})
```

## Modal and Dialog Testing

### Opening and Closing
```javascript
it('should open and close modal', async () => {
  render(<ModalTrigger />)
  
  // Modal not in DOM initially
  expect(queryByRole('dialog')).not.toBeInTheDocument()
  
  // Open modal
  await userEvent.click(getByRole('button', { name: 'Open settings' }))
  expect(getByRole('dialog', { name: 'Settings' })).toBeInTheDocument()
  
  // Close with button
  await userEvent.click(getByRole('button', { name: 'Close' }))
  expect(queryByRole('dialog')).not.toBeInTheDocument()
})
```

### Testing Focus Management
```javascript
it('should trap focus in modal', async () => {
  render(<Modal isOpen={true} />)
  
  const dialog = getByRole('dialog')
  const closeButton = getByRole('button', { name: 'Close' })
  
  // Focus should be inside modal
  expect(dialog).toContainElement(document.activeElement)
  
  // Tab should cycle within modal
  await userEvent.tab()
  expect(dialog).toContainElement(document.activeElement)
})
```

## Error Handling

### Error Boundaries
```javascript
it('should show fallback UI on error', () => {
  const ThrowingComponent = () => { throw new Error('Test error') }
  
  render(
    <ErrorBoundary fallback={<div>Something went wrong</div>}>
      <ThrowingComponent />
    </ErrorBoundary>
  )
  
  expect(getByText('Something went wrong')).toBeInTheDocument()
})
```

### API Error States
```javascript
it('should display error message on API failure', async () => {
  server.use(
    rest.get('/api/data', (req, res, ctx) => 
      res(ctx.status(500), ctx.json({ error: 'Server error' }))
    )
  )
  
  render(<DataFetcher />)
  
  expect(await findByRole('alert')).toHaveTextContent('Failed to load data')
  expect(getByRole('button', { name: 'Retry' })).toBeInTheDocument()
})
```

## Accessibility Testing

### Role and Label Testing
```javascript
it('should have accessible form controls', () => {
  render(<LoginForm />)
  
  // Form inputs have labels
  expect(getByLabelText('Username')).toBeInTheDocument()
  expect(getByLabelText('Password')).toBeInTheDocument()
  
  // Button has accessible name
  expect(getByRole('button', { name: 'Sign in' })).toBeInTheDocument()
})
```

### Keyboard Navigation
```javascript
it('should be keyboard navigable', async () => {
  render(<Menu items={menuItems} />)
  
  await userEvent.tab() // Focus first item
  expect(getByRole('menuitem', { name: menuItems[0].label })).toHaveFocus()
  
  await userEvent.keyboard('{ArrowDown}')
  expect(getByRole('menuitem', { name: menuItems[1].label })).toHaveFocus()
})
```

### Screen Reader Announcements
```javascript
it('should announce status changes', async () => {
  render(<SaveButton />)
  
  await userEvent.click(getByRole('button', { name: 'Save' }))
  
  // Check for live region announcement
  expect(getByRole('status')).toHaveTextContent('Changes saved')
})
```

## Custom Hooks Testing

```javascript
import { renderHook, act } from '@testing-library/react'

it('should toggle state', () => {
  const { result } = renderHook(() => useToggle(false))
  
  expect(result.current.isOn).toBe(false)
  
  act(() => {
    result.current.toggle()
  })
  
  expect(result.current.isOn).toBe(true)
})
```

## Test Data Factories

```javascript
// [CUSTOMIZE] Adapt to your domain models
const createUser = (overrides = {}) => ({
  id: faker.datatype.uuid(),
  name: faker.name.fullName(),
  email: faker.internet.email(),
  role: 'user',
  ...overrides
})

const createUsers = (count, overrides = {}) => 
  Array.from({ length: count }, () => createUser(overrides))
```

## Mock Patterns

### MSW Handlers
```javascript
// [CUSTOMIZE] Add your API endpoints
export const handlers = [
  rest.get('/api/users', (req, res, ctx) => {
    return res(ctx.json({ users: mockUsers }))
  }),
  
  rest.post('/api/users', async (req, res, ctx) => {
    const body = await req.json()
    return res(ctx.json({ id: 'new-id', ...body }))
  })
]
```

### Context Providers Wrapper
```javascript
// [CUSTOMIZE] Include your app's providers
const AllProviders = ({ children }) => (
  <QueryClientProvider client={queryClient}>
    <ThemeProvider>
      <AuthProvider>
        {children}
      </AuthProvider>
    </ThemeProvider>
  </QueryClientProvider>
)

const customRender = (ui, options) =>
  render(ui, { wrapper: AllProviders, ...options })
```
