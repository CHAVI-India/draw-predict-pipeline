# Use official NVIDIA CUDA runtime with Ubuntu 20.04 and cuDNN 8
FROM nvcr.io/nvidia/cuda:13.0.1-cudnn-devel-ubuntu24.04

# Arguments for user/group IDs
ARG UID=1000
ARG GID=1000

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    CONDA_DIR=/home/draw/miniconda3 \
    APP_USER=draw \
    APP_HOME=/draw \
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
    && rm -rf /var/lib/apt/lists/*

# Install Miniconda
RUN wget --quiet https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O /tmp/miniconda.sh && \
    chmod +x /tmp/miniconda.sh && \
    /bin/bash /tmp/miniconda.sh -b -p $CONDA_DIR && \
    rm /tmp/miniconda.sh && \
    # Initialize conda for the root user
    $CONDA_DIR/bin/conda init bash && \
    $CONDA_DIR/bin/conda clean --all -y && \
    # Make conda available system-wide
    ln -s $CONDA_DIR/etc/profile.d/conda.sh /etc/profile.d/conda.sh && \
    echo "export PATH=$CONDA_DIR/bin:$PATH" >> /etc/profile.d/conda.sh && \
    # Initialize conda in the current shell
    . $CONDA_DIR/etc/profile.d/conda.sh && \
    conda config --set auto_activate_base false

# Create non-root user and set up environment with specific UID
# First try with specified GID, if that fails, use next available GID
RUN if ! groupadd -r -g $GID $APP_USER 2>/dev/null; then \
       groupadd -r $APP_USER; \
    fi && \
    # Check if UID is already in use, if so use next available UID
    if ! useradd -m -r -u $UID -g $APP_USER -d $APP_HOME -s /bin/bash $APP_USER 2>/dev/null; then \
        useradd -m -r -g $APP_USER -d $APP_HOME -s /bin/bash $APP_USER; \
    fi && \
    # Set up conda for the non-root user
    mkdir -p $APP_HOME/.conda && \
    chown -R $APP_USER:$APP_USER $APP_HOME $CONDA_DIR && \
    chmod -R 775 $CONDA_DIR && \
    # Add conda to PATH for the non-root user
    echo 'export PATH="$CONDA_DIR/bin:$PATH"' >> $APP_HOME/.bashrc && \
    echo 'source $CONDA_DIR/etc/profile.d/conda.sh' >> $APP_HOME/.bashrc && \
    echo 'conda activate base' >> $APP_HOME/.bashrc && \
    # Fix permissions
    chown -R $APP_USER:$APP_USER $APP_HOME && \
    # Create required directories with proper permissions
    mkdir -p /home/draw/draw/data/nnUNet_results \
             /home/draw/draw/output \
             /home/draw/draw/logs \
             /home/draw/draw/dicom \
             /home/draw/copy_dicom \
             /home/draw/draw/bin && \
    chown -R $APP_USER:$APP_USER /home/draw && \
    find /home/draw -type d -exec chmod 755 {} \; && \
    mkdir -p $EFS_MOUNT && \
    chown -R $APP_USER:$APP_USER $EFS_MOUNT && \
    chmod 755 $EFS_MOUNT

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

# Copy specific application directories and files to /home/draw/draw/
COPY --chown=$APP_USER:$APP_USER bin/ /home/draw/draw/bin/
COPY --chown=$APP_USER:$APP_USER config_yaml/ /home/draw/draw/config_yaml/
COPY --chown=$APP_USER:$APP_USER draw/ /home/draw/draw/draw/

# Copy essential configuration files to /home/draw/draw/
COPY --chown=$APP_USER:$APP_USER requirements.txt /home/draw/draw/
COPY --chown=$APP_USER:$APP_USER environment.yml /home/draw/draw/
COPY --chown=$APP_USER:$APP_USER env.draw.yml /home/draw/draw/
COPY --chown=$APP_USER:$APP_USER alembic.ini /home/draw/draw/
COPY --chown=$APP_USER:$APP_USER main.py /home/draw/draw/
COPY --chown=$APP_USER:$APP_USER entrypoint.sh /home/draw/draw/

# Switch to non-root user
USER $APP_USER

# Set environment for conda
ENV PATH=$CONDA_DIR/envs/draw/bin:$PATH
ENV CONDA_DEFAULT_ENV=draw
ENV CONDA_PREFIX=$CONDA_DIR/envs/$CONDA_DEFAULT_ENV
ENV PATH=$CONDA_PREFIX/bin:$PATH


# Switch to root to create entrypoint script
USER root

# Create entrypoint script with proper permissions
RUN echo '#!/bin/bash\nset -e\n\n# Ensure EFS mount is writable by our user\nif [ -d "$EFS_MOUNT" ]; then\n    chown -R $APP_USER:$APP_USER "$EFS_MOUNT"\n    chmod 755 "$EFS_MOUNT"\nfi\n\n# Execute the main command\nexec "$@"' > /entrypoint.sh && \
    chmod 755 /entrypoint.sh && \
    chown $APP_USER:$APP_USER /entrypoint.sh

# Create conda environment from environment.yml
COPY environment.yml /tmp/
# Create the conda environment
RUN . $CONDA_DIR/etc/profile.d/conda.sh && \
    # Accept Terms of Service for default channels
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main && \
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r && \
    # Create the environment
    conda env create -f /tmp/environment.yml -n draw && \
    conda clean --all -y && \
    rm /tmp/environment.yml && \
    # Initialize conda for the non-root user
    echo "export PATH=$CONDA_DIR/bin:$PATH" >> $APP_HOME/.bashrc && \
    echo ". $CONDA_DIR/etc/profile.d/conda.sh" >> $APP_HOME/.bashrc && \
    echo "conda activate draw" >> $APP_HOME/.bashrc

# Switch to non-root user
USER $APP_USER

# Set the entrypoint and default command
ENTRYPOINT ["/entrypoint.sh"]
# The entrypoint script is already set up to run as the non-root user
CMD ["bash"]
