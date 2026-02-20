# ML stub for Project 5 (CPU-only image; GPU image would use nvidia/cuda base)
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
ENV PORT=8000
EXPOSE 8000
CMD ["python", "app.py"]
