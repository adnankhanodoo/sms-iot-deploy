FROM python:3.11-slim
WORKDIR /app
COPY packages/ /usr/local/lib/python3.11/site-packages/
COPY event_queue.py .
CMD ["python", "-u", "event_queue.py"]
