"""add FAILED status

Revision ID: a1b2c3d4e5f6
Revises: de871710e5d0
Create Date: 2026-08-22 14:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = "a1b2c3d4e5f6"
down_revision: Union[str, None] = "de871710e5d0"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # SQLite does not support ALTER TABLE to modify a column's enum values.
    # The status column is defined as sa.Enum("INIT", "STARTED", "PREDICTED", "SENT")
    # in the original migration.  We need to add "FAILED" to the allowed values.
    #
    # For SQLite, the simplest approach is to use a batch operation to recreate
    # the table with the updated enum.  For MySQL/PostgreSQL, a simple ALTER
    # would work, but batch_alter_table handles both cases.
    with op.batch_alter_table("dicomlog", schema=None) as batch_op:
        batch_op.alter_column(
            "status",
            existing_type=sa.Enum("INIT", "STARTED", "PREDICTED", "SENT", name="status"),
            type_=sa.Enum("INIT", "STARTED", "PREDICTED", "SENT", "FAILED", name="status"),
            existing_nullable=False,
            existing_server_default="INIT",
        )


def downgrade() -> None:
    with op.batch_alter_table("dicomlog", schema=None) as batch_op:
        batch_op.alter_column(
            "status",
            existing_type=sa.Enum("INIT", "STARTED", "PREDICTED", "SENT", "FAILED", name="status"),
            type_=sa.Enum("INIT", "STARTED", "PREDICTED", "SENT", name="status"),
            existing_nullable=False,
            existing_server_default="INIT",
        )
