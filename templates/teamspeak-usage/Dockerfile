# The teamspeak-usage container (tasks/teamspeak.sh): tsusage.py and the SSH
# client it reaches the server's query with. UID is the owner of its data
# folder; ssh needs a passwd entry for the user it runs as.
FROM python:3-alpine
ARG UID=10000
RUN apk add --no-cache openssh-client && adduser -D -H -u "$UID" tsusage
COPY tsusage.py /usr/local/bin/tsusage.py
USER tsusage
CMD ["python3", "-u", "/usr/local/bin/tsusage.py"]
