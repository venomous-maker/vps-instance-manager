# Dockerfile for SSH-enabled container
FROM ubuntu:22.04

# Install SSH server and essential tools
RUN apt-get update && \
    apt-get install -y openssh-server sudo nano vim curl wget htop netcat-openbsd && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Create SSH directory and configure SSH
RUN mkdir /var/run/sshd && \
    echo 'root:rootpassword' | chpasswd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' -i /etc/pam.d/sshd

# Create a script to add users dynamically
COPY add_user.sh /usr/local/bin/add_user.sh
RUN chmod +x /usr/local/bin/add_user.sh

# Create startup script
COPY startup.sh /usr/local/bin/startup.sh
RUN chmod +x /usr/local/bin/startup.sh

# Expose SSH port
EXPOSE 22

# Set environment variables
ENV NOTVISIBLE "in users profile"
RUN echo "export VISIBLE=now" >> /etc/profile

# Start SSH service
CMD ["/usr/local/bin/startup.sh"]