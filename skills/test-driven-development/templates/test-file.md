# Test File Template

## Structure

```java
// src/test/java/com/example/service/[ServiceName]Test.java
package com.example.service;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class ServiceNameTest {

    private DependencyOne dependencyOne;
    private DependencyTwo dependencyTwo;
    private ServiceName service;

    @BeforeEach
    void setUp() {
        dependencyOne = mock(DependencyOne.class);
        dependencyTwo = mock(DependencyTwo.class);
        service = new ServiceName(dependencyOne, dependencyTwo);
    }

    // Group by BEHAVIOR, not method name
    @Nested
    class WhenScenarioOrCondition {

        @Test
        void expectedBehaviorInBusinessLanguage() {
            // Arrange
            var input = createTestInput();
            when(dependencyOne.someMethod()).thenReturn(expectedValue);

            // Act
            var result = service.doSomething(input);

            // Assert
            assertThat(result).satisfies(r -> {
                assertThat(r.getProperty()).isEqualTo(expected);
            });
        }

        @Test
        void anotherBehaviorForSameScenario() {
            // Arrange
            // Act
            // Assert
        }
    }

    @Nested
    class WhenDifferentScenario {
        @Test
        void expectedBehavior() {
            // ...
        }
    }
}
```

## Test Data Builder Example

Create reusable test data builders:

```java
// src/test/java/com/example/builders/UserBuilder.java
package com.example.builders;

import com.example.domain.User;

public class UserBuilder {
    private String id = "test-user-id";
    private String email = "test@example.com";
    private String name = "Test User";
    private int level = 1;
    private int xp = 0;

    public static UserBuilder aUser() {
        return new UserBuilder();
    }

    public UserBuilder withId(String id) {
        this.id = id;
        return this;
    }

    public UserBuilder withEmail(String email) {
        this.email = email;
        return this;
    }

    public UserBuilder withLevel(int level) {
        this.level = level;
        return this;
    }

    public UserBuilder withXp(int xp) {
        this.xp = xp;
        return this;
    }

    public User build() {
        return new User(id, email, name, level, xp);
    }
}
```

## Example: Complete Test File

```java
// src/test/java/com/example/service/LevelingServiceTest.java
package com.example.service;

import com.example.domain.User;
import com.example.repository.UserRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

import static com.example.builders.UserBuilder.aUser;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class LevelingServiceTest {

    private UserRepository repository;
    private LevelingService service;

    @BeforeEach
    void setUp() {
        repository = mock(UserRepository.class);
        service = new LevelingService(repository);
    }

    @Nested
    class WhenUserGainsEnoughXp {

        @Test
        void increasesLevelByOne() {
            User user = aUser().withLevel(1).withXp(100).build();

            service.applyLevelUp(user);

            assertThat(user.getLevel()).isEqualTo(2);
        }

        @Test
        void grantsAttributePoints() {
            User user = aUser().withLevel(1).build();

            service.applyLevelUp(user);

            assertThat(user.getAttributePoints()).isEqualTo(5);
        }

        @Test
        void resetsXpProgress() {
            User user = aUser().withXp(150).build();

            service.applyLevelUp(user);

            assertThat(user.getXp()).isLessThan(150);
        }
    }

    @Nested
    class WhenUserAtMaxLevel {

        @Test
        void doesNotIncreaseLevel() {
            User user = aUser().withLevel(100).build();

            service.applyLevelUp(user);

            assertThat(user.getLevel()).isEqualTo(100);
        }
    }

    @ParameterizedTest
    @CsvSource({
        "1, 100",
        "10, 1000",
        "50, 5000"
    })
    void xpRequirementScalesWithLevel(int level, int expectedXpRequired) {
        int required = service.getXpRequiredForLevel(level);

        assertThat(required).isEqualTo(expectedXpRequired);
    }
}
```

## Checklist

- [ ] Imports from JUnit 5 (jupiter)
- [ ] Uses builder/factory functions for test data
- [ ] Tests organized by behavior/scenario using `@Nested`
- [ ] Each test follows AAA pattern
- [ ] Test names describe expected behavior
- [ ] No reflection to access private members
- [ ] File stays focused (split if > 500 lines)
