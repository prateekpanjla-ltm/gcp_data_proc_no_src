"""
Local test runner for Phase 2 processing.

Reads GitHub Archive JSON files from local storage, processes them,
and writes output to local storage. Useful for development and testing
without requiring GCP infrastructure.

Usage:
    cd src/github_archive/phase2_process_files
    python test_local.py --input data/github_archive/2026-03-05-12.json.gz --output /tmp/output

Or from project root:
    python -m github_archive.phase2_process_files.test_local --input data/github_archive/2026-03-05-12.json.gz
"""

import argparse
import gzip
import json
import sys
from pathlib import Path
from typing import Dict, List, Any

import pandas as pd

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent.parent.parent))

# Import the processing components
from github_archive.phase2_process_files.processors.transformer import GitHubEventTransformer
from github_archive.phase2_process_files.validators.file_validator import validate_chunk
from github_archive.phase2_process_files.schemas.dtype_definitions import BIGQUERY_SCHEMA, get_bigquery_schema_json


def read_json_file(file_path: Path) -> List[Dict[str, Any]]:
    """
    Read a JSON or JSON.gz file and return list of records.

    Handles both regular JSON and gzipped JSON files.
    """
    records = []

    if file_path.suffix == '.gz':
        open_func = gzip.open
        mode = 'rt'
    else:
        open_func = open
        mode = 'r'

    try:
        with open_func(file_path, mode) as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        records.append(json.loads(line))
                    except json.JSONDecodeError as e:
                        print(f"Warning: Skipping invalid JSON line: {e}")
        print(f"Read {len(records)} records from {file_path}")
    except FileNotFoundError:
        print(f"Error: File not found: {file_path}")
        sys.exit(1)
    except Exception as e:
        print(f"Error reading file: {e}")
        sys.exit(1)

    return records


def process_file(
    input_path: Path,
    output_path: Path,
    chunksize: int = 100_000,
    validate: bool = True
) -> Dict[str, Any]:
    """
    Process a GitHub Archive file locally.

    Args:
        input_path: Path to input JSON file (may be gzipped)
        output_path: Path to output directory
        chunksize: Number of records per chunk
        validate: Whether to validate the data

    Returns:
        Processing summary with counts and status
    """
    print(f"\n{'='*60}")
    print(f"Processing: {input_path}")
    print(f"Output to: {output_path}")
    print(f"{'='*60}\n")

    # Create output directory
    output_path.mkdir(parents=True, exist_ok=True)

    # Read input file
    print("Step 1: Reading input file...")
    records = read_json_file(input_path)

    if not records:
        print("No records to process.")
        return {"status": "success", "records_in": 0, "records_out": 0}

    # Convert to DataFrame
    print("Step 2: Converting to DataFrame...")
    df = pd.DataFrame(records)
    print(f"  DataFrame shape: {df.shape}")
    print(f"  Columns: {list(df.columns)}")

    # Transform data
    print("\nStep 3: Transforming data...")
    transformer = GitHubEventTransformer()
    result = transformer.transform_chunk(df)
    transformed_df = result.df

    print(f"  Records in: {result.records_in}")
    print(f"  Records out: {result.records_out}")
    print(f"  Errors: {result.error_count}")

    # Show sample of transformed data
    print("\n  Sample transformed record:")
    if not transformed_df.empty:
        sample = transformed_df.iloc[0].to_dict()
        for key, value in list(sample.items())[:5]:
            print(f"    {key}: {value}")
        print(f"    ... ({len(sample)} total fields)")

    # Validate data
    validation_results = {}
    if validate and not transformed_df.empty:
        print("\nStep 4: Validating data...")
        result = validate_chunk(transformed_df)

        validation_results = {
            'is_valid': result.is_valid,
            'records_in': result.records_in,
            'records_out': result.records_out,
            'errors': result.errors,
            'warnings': result.warnings
        }

        print(f"  Validation: {'PASSED' if result.is_valid else 'FAILED'}")
        print(f"  Records: {result.records_in} in, {result.records_out} out")

        if result.errors:
            print("  Errors:")
            for field, count in result.errors.items():
                print(f"    {field}: {count}")

        if result.warnings:
            print("  Warnings:")
            for field, count in result.warnings.items():
                print(f"    {field}: {count}")

        if result.valid_df is not None:
            transformed_df = result.valid_df

    # Write output
    print("\nStep 5: Writing output files...")
    base_name = input_path.stem
    if base_name.endswith('.json'):
        base_name = base_name[:-5]

    # Determine compression based on input
    use_gzip = input_path.suffix == '.gz'

    output_file = output_path / f"{base_name}_processed.ndjson"
    if use_gzip:
        output_file = output_path / f"{base_name}_processed.ndjson.gz"

    # Write in chunks to handle large files
    records_written = 0
    chunk_count = 0
    max_file_size = 500 * 1024 * 1024  # 500MB

    for start_idx in range(0, len(transformed_df), chunksize):
        end_idx = min(start_idx + chunksize, len(transformed_df))
        chunk_df = transformed_df.iloc[start_idx:end_idx]

        # Check if we need to split files
        if records_written > 0 and records_written % (max_file_size // 1000) == 0:
            chunk_count += 1
            suffix = f"_part{chunk_count}"
            if use_gzip:
                current_output = output_path / f"{base_name}_processed{suffix}.ndjson.gz"
            else:
                current_output = output_path / f"{base_name}_processed{suffix}.ndjson"
        else:
            current_output = output_file

        # Write chunk
        if use_gzip:
            with gzip.open(current_output, 'at' if records_written > 0 else 'wt') as f:
                for record in chunk_df.to_dict('records'):
                    f.write(json.dumps(record, default=str) + '\n')
        else:
            with open(current_output, 'a' if records_written > 0 else 'w') as f:
                for record in chunk_df.to_dict('records'):
                    f.write(json.dumps(record, default=str) + '\n')

        records_written += len(chunk_df)

    print(f"  Written {records_written} records to {output_file}")

    # Show BigQuery schema
    print("\n" + "="*60)
    print("BigQuery Schema (for reference):")
    print("="*60)
    schema_json = get_bigquery_schema_json()
    print(schema_json[:500] + "..." if len(schema_json) > 500 else schema_json)

    # Summary
    summary = {
        "status": "success",
        "input_file": str(input_path),
        "output_file": str(output_file),
        "records_in": stats['total_records_in'],
        "records_out": stats['total_records_out'],
        "records_written": records_written,
        "errors": stats['total_errors'],
        "validation": validation_results
    }

    print(f"\n{'='*60}")
    print("SUMMARY")
    print(f"{'='*60}")
    print(f"Input file:        {summary['input_file']}")
    print(f"Output file:       {summary['output_file']}")
    print(f"Records in:        {summary['records_in']:,}")
    print(f"Records out:       {summary['records_out']:,}")
    print(f"Records written:   {summary['records_written']:,}")
    print(f"Errors:            {summary['errors']:,}")
    if validation_results:
        print(f"Validation:        {validation_results['is_valid']}")
        print(f"Invalid records:   {validation_results['invalid_count']:,}")

    return summary


def main():
    """Main entry point for local testing."""
    parser = argparse.ArgumentParser(
        description='Process GitHub Archive data locally'
    )
    parser.add_argument(
        '--input', '-i',
        type=str,
        required=True,
        help='Input file path (JSON or JSON.gz)'
    )
    parser.add_argument(
        '--output', '-o',
        type=str,
        default='/tmp/github_events_processed',
        help='Output directory path (default: /tmp/github_events_processed)'
    )
    parser.add_argument(
        '--chunksize',
        type=int,
        default=100_000,
        help='Number of records per chunk (default: 100000)'
    )
    parser.add_argument(
        '--no-validate',
        action='store_true',
        help='Skip validation step'
    )

    args = parser.parse_args()

    input_path = Path(args.input)
    output_path = Path(args.output)

    if not input_path.exists():
        print(f"Error: Input file not found: {input_path}")
        sys.exit(1)

    try:
        summary = process_file(
            input_path=input_path,
            output_path=output_path,
            chunksize=args.chunksize,
            validate=not args.no_validate
        )
        print(f"\nProcessing complete!")
        sys.exit(0)

    except Exception as e:
        print(f"\nError during processing: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == '__main__':
    main()
