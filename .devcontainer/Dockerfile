FROM swift:latest

RUN apt-get update
RUN apt-get install -y \
    zsh \
    libsqlite3-dev \
    libncurses5-dev \
    apt-transport-https \
    ca-certificates \
    vim

RUN mkdir -p ~/.ssh
RUN ssh-keyscan -t rsa github.com >> ~/.ssh/known_hosts

CMD ["zsh"]