FROM python:3.12-alpine
WORKDIR /app
RUN pip install --no-cache-dir pg8000==1.31.2
COPY app.py .
EXPOSE 8080
CMD ["python", "app.py"]
