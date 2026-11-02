FROM fnproject/python:3.11-dev AS build
WORKDIR /function
COPY requirements.txt .
RUN pip3 install --target /python/ --no-cache-dir -r requirements.txt
COPY func.py .

FROM fnproject/python:3.11
WORKDIR /function
COPY --from=build /python /python
COPY --from=build /function /function
ENV PYTHONPATH=/function:/python
ENTRYPOINT ["/python/bin/fdk", "/function/func.py", "handler"]
