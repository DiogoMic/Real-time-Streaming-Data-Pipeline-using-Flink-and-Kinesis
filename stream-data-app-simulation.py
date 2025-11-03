import boto3
import csv
import json
import os
import dateutil.parser as parser
from time import sleep
from datetime import datetime, timezone
from botocore.exceptions import ClientError
import io


# AWS Settings - configurable through environment variables
AWS_REGION = os.getenv('AWS_REGION', 'eu-west-1')
s3 = boto3.client('s3', region_name=AWS_REGION)
s3_resource = boto3.resource('s3', region_name=AWS_REGION)
kinesis_client = boto3.client('kinesis', region_name=AWS_REGION)

# Env. variables; i.e. can be OS variables in Lambda
kinesis_stream_name = os.getenv('KINESIS_STREAM_NAME', 'US_Car_Accidents_Data_Stream-1')
streaming_partition_key = os.getenv('PARTITION_KEY', 'Severity')
S3_BUCKET = os.getenv('S3_BUCKET', 'projectpro-project1-rawdata-car-incidents')
S3_KEY = os.getenv('S3_KEY', 'raw_data/US_Accidents_Dec20_updated.csv')


# Function can be converted to Lambda; 
#   i.e. by iterating the S3-put events records; e.g. record['s3']['bucket']['name']
def parse_datetime_field(data, field_name):
    """Parse and convert datetime field to ISO format"""
    try:
        data[field_name] = parser.parse(data[field_name]).isoformat()
    except (ValueError, TypeError) as e:
        print(f'Error parsing {field_name}: {e}')
        data[field_name] = None

def stream_data_simulator(input_s3_bucket, input_s3_key):
  # Stream CSV processing to handle large files
  try:
    csv_file = s3_resource.Object(input_s3_bucket, input_s3_key)
    s3_response = csv_file.get()
    
    # Use streaming to avoid loading entire file into memory
    csv_content = io.TextIOWrapper(s3_response['Body'], encoding='utf-8')
    csv_reader = csv.DictReader(csv_content)
    
    for row in csv_reader:
      try:
          # Work directly with CSV row dictionary
          json_load = row.copy()
          
          # Simple date casting:
          parse_datetime_field(json_load, 'Start_Time')
          parse_datetime_field(json_load, 'End_Time')
          parse_datetime_field(json_load, 'Weather_Timestamp')
          
          # Adding fake txn ts (Flink-compatible format):
          json_load['Txn_Timestamp'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S')
          
          # Write to Kinesis Streams:
          response = kinesis_client.put_record(
              StreamName=kinesis_stream_name,
              Data=json.dumps(json_load),
              PartitionKey=str(json_load[streaming_partition_key])
          )
          print(response)
          
          # Adding a temporary pause, for demo-purposes:
          sleep(0.250)
          
      except (ClientError, ConnectionError) as e:
          print(f'AWS/Network Error: {e}')
          break
      except Exception as e:
          print(f'Processing Error: {e}')
          continue
  
  except (ClientError, ConnectionError) as e:
    print(f'S3 Connection Error: {e}')
    raise
  except Exception as e:
    print(f'Unexpected Error: {e}')
    raise

# Run stream with retry logic:
for i in range(0, 3):
  max_retries = 3
  for retry in range(max_retries):
    try:
      stream_data_simulator(input_s3_bucket=S3_BUCKET, input_s3_key=S3_KEY)
      break  # Success, exit retry loop
    except Exception as e:
      print(f'Error in stream iteration {i}, retry {retry + 1}: {e}')
      if retry < max_retries - 1:
        sleep(2 ** retry)  # Exponential backoff
      else:
        print(f'Failed after {max_retries} retries')
