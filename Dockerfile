# Use NVIDIA CUDA base image
FROM nvidia/cuda:13.0.1-cudnn8-devel-ubuntu24.04

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
    && rm -rf /var/lib/apt/lists/*

# Install Miniconda
RUN wget --quiet https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O ~/miniconda.sh && \
    /bin/bash ~/miniconda.sh -b -p $CONDA_DIR && \
    rm ~/miniconda.sh && \
    $CONDA_DIR/bin/conda clean -tipsy && \
    ln -s $CONDA_DIR/etc/profile.d/conda.sh /etc/profile.d/conda.sh && \
    echo ". $CONDA_DIR/etc/profile.d/conda.sh" >> ~/.bashrc

# Create non-root user and set up environment with specific UID/GID
RUN groupadd -r -g $GID $APP_USER && \
    useradd -m -r -u $UID -g $GID -d $APP_HOME -s /bin/bash $APP_USER && \
    chown -R $APP_USER:$APP_USER $APP_HOME && \
    mkdir -p $EFS_MOUNT && \
    chown -R $APP_USER:$APP_USER $EFS_MOUNT

# Set working directory and switch to non-root user
WORKDIR $APP_HOME
USER $APP_USER

# Copy environment file first for better caching
COPY --chown=$APP_USER:$APP_USER environment.yml .

# Create and activate conda environment
RUN $CONDA_DIR/bin/conda env create -f environment.yml && \
    $CONDA_DIR/bin/conda clean -afy

# Copy application code
COPY --chown=$APP_USER:$APP_USER . .

# Set environment for conda
ENV PATH=$CONDA_DIR/envs/draw/bin:$PATH
ENV CONDA_DEFAULT_ENV=draw
ENV CONDA_PREFIX=$CONDA_DIR/envs/$CONDA_DEFAULT_ENV
ENV PATH=$CONDA_PREFIX/bin:$PATH

# Create necessary directories with correct permissions
RUN mkdir -p logs output data/nnUNet_results data/nnunet_results && \
    chown -R $APP_USER:$APP_USER logs output data

# Create entrypoint script
RUN echo '#!/bin/bash\n\
# Ensure EFS mount is writable by our user\nif [ -d "$EFS_MOUNT" ]; then\n    chown -R $APP_USER:$APP_USER $EFS_MOUNT\n    chmod 755 $EFS_MOUNT\nfi\n\n# Execute the main command\nexec "$@"' > /entrypoint.sh && \
    chmod +x /entrypoint.sh

# Set the entrypoint
ENTRYPOINT ["/entrypoint.sh"]

# Default command (can be overridden)
CMD ["conda", "run", "--no-capture-output", "-n", "draw", "./entrypoint.sh"]
