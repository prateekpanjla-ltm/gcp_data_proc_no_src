"""
Cloud Run Service entry point for GitHub Archive Phase 2 processing.

Receives Eventarc events when files land in the landing bucket,
validates, transforms, and writes them to the staging bucket.
"""

import logging
import os

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(name)s: %(message)s')

from flask import Flask, request, jsonify
from google.api_core import exceptions as gcp_exceptions
from google.cloud import storage
from processors.file_processor import process_file


# =============================================================================
# CONFIGURATION
# =============================================================================
PROJECT_ID = os.getenv('PROJECT_ID')
LANDING_BUCKET = os.getenv('LANDING_BUCKET')
STAGING_BUCKET = os.getenv('STAGING_BUCKET')
FILE_SIZE_THRESHOLD_MB = int(os.getenv('FILE_SIZE_THRESHOLD_MB', '50'))
CHUNKSIZE = int(os.getenv('CHUNKSIZE', '100000'))

# Cloud Run requires 0.0.0.0 binding
HOST = '0.0.0.0'
PORT = int(os.getenv('PORT', '8080'))

# =============================================================================
# APP INITIALIZATION
# =============================================================================
app = Flask(__name__)

# Initialize logger
logger = logging.getLogger('phase2-processor')

# Initialize storage client
storage_client = storage.Client(project=PROJECT_ID)


# =============================================================================
# HEALTH CHECK
# =============================================================================
@app.route('/', methods=['GET'])
@app.route('/health', methods=['GET'])
def health_check():
    """Health check endpoint."""
    return jsonify({
        'status': 'healthy',
        'service': 'github-archive-processor',
        'project': PROJECT_ID,
        'landing_bucket': LANDING_BUCKET,
        'staging_bucket': STAGING_BUCKET
    }), 200



# =============================================================================
# MAIN PROCESSING HANDLER (Eventarc trigger)
# =============================================================================
@app.route('/', methods=['POST'])
def process_file_event():
    """
    Handle Eventarc event for new files in landing bucket.

    Expected Cloud Storage event format:
    {
        "bucket": "bucket-name",
        "name": "path/to/file.json.gz",
        "resourceState": "exists",
        "metageneration": "1"
    }
    """
    # Parse event payload
    try:
        event = request.get_json()
        if not event:
            return jsonify({'error': 'No event payload'}), 400

    except Exception as e:
        logger.error(f"Failed to parse event: {e}")
        return jsonify({'error': f'Invalid event payload: {e}'}), 400

    # Extract event data
    bucket = event.get('bucket')
    file_name = event.get('name')

    logger.info(f"Received Eventarc event: bucket={bucket}, file={file_name}")

    # Path filtering: Only process files in github-archive/raw/*.json.gz
    reason = None
    if not file_name or not file_name.startswith('github-archive/'):
        reason = 'path_not_matching'
    elif not file_name.endswith('.json.gz'):
        reason = 'extension_not_matching'
    elif '/raw/' not in file_name:
        reason = 'subdirectory_not_matching'

    if reason:
        logger.info(f"Ignoring file: {file_name} ({reason})")
        return jsonify({'status': 'ignored', 'reason': reason}), 200

    # Build full GCS path
    input_gcs_path = f"gs://{bucket}/{file_name}"

    # Check file size before processing
    try:
        blob = storage_client.bucket(bucket).blob(file_name)
        blob.reload()
        file_size_mb = blob.size / (1024 * 1024)
        if file_size_mb > FILE_SIZE_THRESHOLD_MB:
            logger.error(f"File too large: {file_name} ({file_size_mb:.1f}MB) exceeds {FILE_SIZE_THRESHOLD_MB}MB threshold")
            return jsonify({
                'status': 'rejected',
                'error': f'File exceeds {FILE_SIZE_THRESHOLD_MB}MB threshold',
                'input_file': input_gcs_path
            }), 413
    except (gcp_exceptions.Forbidden, gcp_exceptions.NotFound) as e:
        logger.error(f"Failed to get file metadata for {file_name}: {e}")
        return jsonify({'status': 'error', 'error': str(e)}), 500

    # Process the file
    try:
        result = process_file(input_gcs_path, PROJECT_ID, STAGING_BUCKET, CHUNKSIZE)

        # Normal processing response
        response_data = {
            'status': 'success' if result.success else 'failed',
            'input_file': result.input_file,
            'output_file': result.output_file,
            'output_files': result.output_files or [],
            'output_count': len(result.output_files),
            'records_in': result.records_in,
            'records_out': result.records_out,
            'errors': result.errors,
            'warnings': result.warnings
        }

        status_code = 200 if result.success else 207  # 207 for partial success

        logger.info(f"Processing {'completed' if result.success else 'failed'}: {file_name}, in={result.records_in}, out={result.records_out}")

        return jsonify(response_data), status_code

    except Exception as e:
        error_msg = f"Processing error: {str(e)}"
        logger.error(f"{error_msg} file={file_name}")

        return jsonify({
            'status': 'error',
            'error': error_msg
        }), 500



# =============================================================================
# MAIN
# =============================================================================
if __name__ == '__main__':
    logger.info(f"Starting GitHub Archive Processor: project={PROJECT_ID}, landing={LANDING_BUCKET}, staging={STAGING_BUCKET}, port={PORT}")

    app.run(host=HOST, port=PORT, debug=False)
