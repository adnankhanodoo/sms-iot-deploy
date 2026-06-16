FROM python:3.11-slim
WORKDIR /app
RUN pip install paho-mqtt requests --default-timeout=300 --retries=5
COPY event_queue.py .
CMD ["python", "-u", "event_queue.py"]
