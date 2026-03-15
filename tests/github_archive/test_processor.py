"""Unit tests for GitHub Archive processor."""

import pytest
from datetime import datetime
from unittest.mock import Mock, patch

from src.github_archive.processor import (
    GitHubArchiveProcessor,
    ProcessingResult,
    create_bigquery_table
)


class TestGitHubArchiveProcessor:
    """Unit tests for GitHub Archive processing logic."""

    @pytest.fixture
    def mock_storage(self):
        """Mock StorageClient."""
        return Mock()

    @pytest.fixture
    def mock_bq(self):
        """Mock BigQueryClient."""
        return Mock()

    @pytest.fixture
    def processor(self, mock_storage, mock_bq):
        """Create a processor instance with mocked clients."""
        return GitHubArchiveProcessor(
            storage_client=mock_storage,
            bq_client=mock_bq
        )

    def test_parse_push_event(self, processor):
        """Test parsing a PushEvent."""
        raw_event = {
            "id": "1234567890",
            "type": "PushEvent",
            "actor": {
                "id": 12345,
                "login": "testuser",
                "display_login": "Test User",
                "gravatar_id": "",
                "url": "https://api.github.com/users/testuser",
                "avatar_url": "https://avatars.githubusercontent.com/u/12345?"
            },
            "repo": {
                "id": 67890,
                "name": "test/repo",
                "url": "https://api.github.com/repos/test/repo"
            },
            "payload": {
                "push_id": 1234567890,
                "size": 5,
                "distinct_size": 3,
                "ref": "refs/heads/main",
                "head": "abc123",
                "before": "def456"
            },
            "public": True,
            "created_at": "2025-01-15T14:30:00Z"
        }

        result = processor.parse_event(raw_event)

        assert result is not None
        assert result["event_id"] == "1234567890"
        assert result["event_type"] == "PushEvent"
        assert result["actor_login"] == "testuser"
        assert result["repo_name"] == "test/repo"
        assert result["push_size"] == 5
        assert result["push_distinct_size"] == 3
        assert result["ref"] == "refs/heads/main"

    def test_parse_watch_event(self, processor):
        """Test parsing a WatchEvent."""
        raw_event = {
            "id": "1234567891",
            "type": "WatchEvent",
            "actor": {
                "id": 12345,
                "login": "testuser"
            },
            "repo": {
                "id": 67890,
                "name": "test/repo"
            },
            "payload": {
                "action": "started"
            },
            "public": True,
            "created_at": "2025-01-15T14:30:00Z"
        }

        result = processor.parse_event(raw_event)

        assert result is not None
        assert result["event_id"] == "1234567891"
        assert result["event_type"] == "WatchEvent"
        assert result["action"] == "started"

    def test_parse_pull_request_event(self, processor):
        """Test parsing a PullRequestEvent."""
        raw_event = {
            "id": "1234567892",
            "type": "PullRequestEvent",
            "actor": {"id": 12345, "login": "testuser"},
            "repo": {"id": 67890, "name": "test/repo"},
            "payload": {
                "action": "opened",
                "pull_request": {
                    "number": 42,
                    "title": "Fix bug",
                    "state": "open",
                    "merged": False
                }
            },
            "public": True,
            "created_at": "2025-01-15T14:30:00Z"
        }

        result = processor.parse_event(raw_event)

        assert result is not None
        assert result["event_type"] == "PullRequestEvent"
        assert result["pr_number"] == 42
        assert result["pr_title"] == "Fix bug"
        assert result["pr_state"] == "open"
        assert result["pr_merged"] is False

    def test_parse_event_missing_required_fields(self, processor):
        """Test that events without required fields are skipped."""
        invalid_event = {"id": "123"}  # Missing type and created_at

        result = processor.parse_event(invalid_event)

        assert result is None

    def test_extract_common_payload_fields(self, processor):
        """Test extraction of common payload fields."""
        payload = {
            "action": "opened",
            "ref": "refs/heads/main",
            "ref_type": "branch",
            "master_branch": "main",
            "description": "Test repo"
        }

        fields = processor._extract_common_payload_fields("CreateEvent", payload)

        assert fields["action"] == "opened"
        assert fields["ref"] == "refs/heads/main"
        assert fields["ref_type"] == "branch"
        assert fields["master_branch"] == "main"
        assert fields["description"] == "Test repo"

    def test_process_gcs_event(self, processor, mock_storage):
        """Test processing a GCS event."""
        event_data = {
            "bucket": "test-bucket",
            "name": "github-archive/raw/2025-01-15-14.json.gz"
        }

        # Mock file reading
        mock_events = [
            {"id": "1", "type": "PushEvent", "actor": {"id": 1, "login": "user1"},
             "repo": {"id": 1, "name": "user1/repo1"}, "payload": {},
             "public": True, "created_at": "2025-01-15T14:30:00Z"},
            {"id": "2", "type": "WatchEvent", "actor": {"id": 2, "login": "user2"},
             "repo": {"id": 2, "name": "user2/repo2"}, "payload": {"action": "started"},
             "public": True, "created_at": "2025-01-15T14:30:00Z"}
        ]

        # Mock the iterator for read_jsonl_file
        mock_storage.read_jsonl_file.return_value = iter(mock_events)
        mock_storage.bucket.blob.return_value = None  # Simplified mock

        result = processor.process_gcs_event(event_data)

        assert result.total_events == 2
        assert result.processed_events == 2
        assert result.failed_events == 0


class TestProcessingResult:
    """Tests for ProcessingResult dataclass."""

    def test_result_initialization(self):
        """Test ProcessingResult initialization."""
        result = ProcessingResult(source_file="test.json.gz")

        assert result.source_file == "test.json.gz"
        assert result.total_events == 0
        assert result.processed_events == 0
        assert result.failed_events == 0
        assert result.errors == []

    def test_add_error(self):
        """Test adding errors to result."""
        result = ProcessingResult(source_file="test.json.gz")
        result.add_error("Test error")

        assert len(result.errors) == 1
        assert result.errors[0] == "Test error"
