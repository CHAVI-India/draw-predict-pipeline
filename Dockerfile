# Use official NVIDIA CUDA runtime with Ubuntu 20.04 and cuDNN 8
FROM nvcr.io/nvidia/cuda:12.2.0-cudnn8-devel-ubuntu22.04

# Arguments for user/group IDs
ARG UID=1000
ARG GID=1000

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    CONDA_DIR=/home/draw/miniconda3 \
    APP_USER=appuser \
    APP_HOME=/app \
    EFS_MOUNT=/mnt/efs

# Install system dependencies and clean up in one layer
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    curl \
    git \
    build-essential \
    ca-certificates \
    inotify-tools \
    unzip \
    screen \
    awscli \
    && rm -rf /var/lib/apt/lists/*

# Install Miniconda
RUN wget --quiet https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O ~/miniconda.sh && \
    chmod +x ~/miniconda.sh && \
    /bin/bash ~/miniconda.sh -b -p $CONDA_DIR && \
    rm ~/miniconda.sh && \
    $CONDA_DIR/bin/conda init bash && \
    $CONDA_DIR/bin/conda clean --all -y && \
    echo "source $CONDA_DIR/etc/profile.d/conda.sh" >> ~/.bashrc && \
    echo "conda activate base" >> ~/.bashrc && \
    ln -s $CONDA_DIR/etc/profile.d/conda.sh /etc/profile.d/conda.sh

# Create non-root user and set up environment with specific UID/GID
RUN groupadd -r -g $GID $APP_USER && \
    useradd -m -r -u $UID -g $GID -d $APP_HOME -s /bin/bash $APP_USER && \
    chown -R $APP_USER:$APP_USER $APP_HOME && \
    # Create required directories with proper permissions
    mkdir -p /home/draw/data/nnUNet_results \
             /home/draw/output \
             /home/draw/logs \
             /home/draw/dicom \
             /home/draw/copy_dicom \
             /home/draw/draw/data \
    && chown -R $APP_USER:$APP_USER /home/draw \
    && chmod 755 /home/draw/* \
    mkdir -p $EFS_MOUNT && \
    chown -R $APP_USER:$APP_USER $EFS_MOUNT

# Set working directory and switch to non-root user
WORKDIR $APP_HOME
USER $APP_USER

# Clean conda cache to reduce image size
RUN $CONDA_DIR/bin/conda clean -afy

# These environment variables should be provided by AWS Batch job definition
# Example AWS Batch job definition overrides:
# {
#   "containerOverrides": [{
#     "environment": [
#       {"name": "inputS3Path", "value": "s3://your-input-bucket/input.zip"},
#       {"name": "outputS3Path", "value": "s3://your-output-bucket/"},
#       {"name": "seriesInstanceUID", "value": "1.2.3.4.5.6.7.8.9.10"},
#       {"name": "studyInstanceUID", "value": "1.2.3.4.5.6.7.8.9.11"},
#       {"name": "patientID", "value": "PATIENT123"},
#       {"name": "transactionToken", "value": "your-transaction-token"},
#       {"name": "fileUploadId", "value": "unique-file-upload-id"}
#     ]
#   }]
# }

# Define environment variables with empty defaults
ENV inputS3Path="" \
    outputS3Path="" \
    seriesInstanceUID="" \
    studyInstanceUID="" \
    patientID="" \
    transactionToken="" \
    fileUploadId=""

# Copy application code
COPY --chown=$APP_USER:$APP_USER . .

# Switch to non-root user
USER $APP_USER

# Set environment for conda
ENV PATH=$CONDA_DIR/envs/draw/bin:$PATH
ENV CONDA_DEFAULT_ENV=draw
ENV CONDA_PREFIX=$CONDA_DIR/envs/$CONDA_DEFAULT_ENV
ENV PATH=$CONDA_PREFIX/bin:$PATH

# Create necessary directories with correct permissions
RUN mkdir -p /home/draw/logs /home/draw/output /home/draw/data/nnUNet_results /home/draw/data/nnunet_results && \
    chown -R $APP_USER:$APP_USER /home/draw/logs /home/draw/output /home/draw/data

# Create entrypoint script
RUN echo '#!/bin/bash\nset -e\n\n# Ensure EFS mount is writable by our user\nif [ -d "$EFS_MOUNT" ]; then\n    chown -R $APP_USER:$APP_USER "$EFS_MOUNT"\n    chmod 755 "$EFS_MOUNT"\nfi\n\n# Execute the main command\nexec "$@"' > /entrypoint.sh && \
    chmod +x /entrypoint.sh


# Set the entrypoint and default command
ENTRYPOINT ["/entrypoint.sh"]
CMD ["conda", "run", "--no-capture-output", "-n", "draw", "bash", "/home/draw/entrypoint.sh"]
