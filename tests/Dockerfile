# Use a lightweight python base image
FROM python:3.11-slim

# Set working directory
WORKDIR /app

# Copy the load tester script
COPY load_tester.py /app/load_tester.py

# Run the python load tester script when container starts
# We use host.docker.internal as default to point to Windows host machine
ENTRYPOINT ["python", "load_tester.py"]
CMD ["--ip", "host.docker.internal", "--port", "27015", "--rate", "60"]
