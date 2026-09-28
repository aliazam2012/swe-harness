# Python Code Examples — Reference

## Table of Contents

- [Import Organization](#import-organization)
- [Parameter Naming](#parameter-naming)
- [Type Hints](#type-hints)
- [Pydantic Validators](#pydantic-validators)
- [API Response Models](#api-response-models)
- [Error Handling](#error-handling)
- [Import Order](#import-order)

---

## Import Organization

### ❌ BAD — Import inside function
```python
def some_function():
    import json
    from app.core.db import get_connection
```

### ✅ GOOD — All imports at the top
```python
import json
import logging
from typing import Any, Optional

from app.core.db import get_connection
from app.services.some_service import SomeService
```

### ✅ ACCEPTABLE — Deferred import (with reason)
```python
# Circular import resolution
def get_service():
    from app.services.my_service import MyService  # Avoids circular import
    return MyService()

# Factory that defers to avoid import-time side effects
def get_db_connection():
    from app.core.db import create_connection  # Deferred to avoid import-time side effects
    return create_connection()
```

---

## Parameter Naming

### ❌ BAD
```python
@field_validator("domain")
def validate_domain(cls, v):  # 'v' is not descriptive
    return v.strip()

def create_item(self, data: ItemCreate):  # 'data' is too generic
    pass
```

### ✅ GOOD
```python
@field_validator("domain")
def validate_domain(cls, domain_value: str) -> str:
    return domain_value.strip()

def create_item(self, item_data: ItemCreate) -> ItemResponse:
    pass
```

---

## Type Hints

```python
# Required field
@field_validator("domain")
def validate_domain(cls, domain_value: str) -> str:
    return domain_value.strip()

# Optional field
@field_validator("domain")
def validate_domain(cls, domain_value: Optional[str]) -> Optional[str]:
    if domain_value is None:
        return None
    return domain_value.strip()

# Service method
def get_item_by_uuid(
    self,
    item_uuid: str,
    include_deleted: bool = False
) -> Optional[ItemResponse]:
    pass

# Route handler
async def create_item(
    item_data: ItemCreate = Body(...),
    service: ItemService = Depends(get_item_service),
) -> ItemResponse:
    pass
```

---

## Pydantic Validators

### Complete Validator Example
```python
@field_validator("domain")
def validate_domain(cls, domain_value: str) -> str:
    """
    Validate and normalize domain.

    Args:
        domain_value: The domain string to validate

    Returns:
        Normalized domain string (trimmed)

    Raises:
        ValueError: If domain is empty, too long, or contains invalid characters
    """
    if not domain_value:
        raise ValueError("domain cannot be empty")

    domain_value = domain_value.strip()

    if not domain_value:
        raise ValueError("domain cannot be empty or whitespace only")

    if len(domain_value) > 255:
        raise ValueError("domain exceeds maximum length of 255 characters")

    if not DOMAIN_PATTERN.match(domain_value):
        raise ValueError(
            "domain contains invalid characters. "
            "Allowed: alphanumeric, dots, hyphens, underscores"
        )

    return domain_value
```

---

## API Response Models

### ❌ BAD — Returning raw dict
```python
@router.get("/items/{item_id}")
async def get_item(item_id: str):
    item = service.get(item_id)
    return {"status": "success", "item": item}
```

### ✅ GOOD — Returning Pydantic model
```python
@router.get("/items/{item_id}", response_model=ItemResponse)
async def get_item(item_id: str) -> ItemResponse:
    item = service.get(item_id)
    return item
```

---

## Error Handling

### Exception Handling Pattern
```python
try:
    # Business logic
except HTTPException:
    raise  # Re-raise HTTPExceptions — don't swallow them
except Exception as e:
    logger.error(f"Failed to process {resource_id}: {e}", exc_info=True)
    raise HTTPException(status_code=500, detail=str(e))
```

---

## Import Order

### PEP 8 Style
```python
import json
import logging
import uuid
from typing import Any, Optional

import boto3
from fastapi import APIRouter, HTTPException

from app.core import config
from app.services.my_service import MyService
```

Each group separated by a blank line. Alphabetical within groups.
