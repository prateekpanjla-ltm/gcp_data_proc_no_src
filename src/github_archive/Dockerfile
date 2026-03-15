# Use the current, correct base image for Google Cloud CLI tools like gsutil.
# The old 'gcr.io/google.com/cloud-sdk:slim' is deprecated and will cause build failures.
FROM gcr.io/google.com/cloudsdktool/google-cloud-cli:slim

# Copy the download script into the container.
COPY phase1_ingestion/scripts/download.sh /scripts/download.sh

# Fix Windows CRLF line endings and make the script executable.
RUN sed -i 's/\r$//' /scripts/download.sh && chmod +x /scripts/download.sh

# Set the entrypoint for the container to run the download script.
ENTRYPOINT ["/scripts/download.sh"]