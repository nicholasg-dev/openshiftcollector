import requests
import json
import logging

# Set logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s %(message)s')
logger = logging.getLogger(__name__)  # pylint: disable=invalid-name

# Disable SSL warning messages
requests.packages.urllib3.disable_warnings()


class CloudBoltConstants:
    CLOUDBOLT_BEARER_TOKEN = ''
    OPENSHIFT_URL = 'https://sc1001.kumolus.net/reportapi/api/v2/openshift/utilization/reports'
    REQUEST_HEADERS = {
        "Content-Type": "application/json",
        "Authorization": "Bearer {}".format(CLOUDBOLT_BEARER_TOKEN)
    }
    START_DATE = '2024-04-1'
    END_DATE = '2024-05-15'

class CloudBoltOpenshiftMetrics(CloudBoltConstants):
    def __init__(self):
        self.name_space_wise_response = []
        self.node_id_wise_reponse = []
        self.capacity_map_array = []

    def save_capacity_data(self, capacity_payload):
        while 1:
            logger.info('sending paginated request for capacity data, please wait...')
            response = requests.post(CloudBoltConstants.OPENSHIFT_URL, json=capacity_payload, headers=CloudBoltConstants.REQUEST_HEADERS)
            if response.status_code == 200:
                response = json.loads(response.content)
                self.capacity_map_array = self.capacity_map_array + response["response"]
                if response['next_token'] == None:
                    break
                capacity_payload['exec_id'] = response['exec_id']
                capacity_payload['next_token'] = response['next_token']
            else:
                logger.info("Return unexpected status for capacity request. API status_code: {}, Content: {}".format(response.status_code, response.content.decode('utf-8')))
                break

    def request_openshift_report_api(self, payload):
        while 1:
            logger.info('sending request for openshift telemetry data, please wait...')
            response = requests.post(CloudBoltConstants.OPENSHIFT_URL, json=payload, headers=CloudBoltConstants.REQUEST_HEADERS)

            if response.status_code == 200:
                # Logic for greater value
                logger.info("Success: {}".format(response.status_code))
                response = json.loads(response.content)
                logger.info('Evaluating response!!!')
                for result in response['response']:
                    usage_percentages = self.__metric_usage_percentage(result)
                    name_space_utilization = self.__namespace_wise_utilization_dict(result, usage_percentages)
                    # self.__build_namespace_result(name_space_utilization)
                    self.__build_node_id_wise_result(result['node_id'], result['node_name'], name_space_utilization.copy())
                if response['next_token'] == None:
                    break
                payload['exec_id'] = response['exec_id']
                payload['next_token'] = response['next_token']
            else:
                logger.info("Return unexpected status. API status_code: {}, Content: {}".format(response.status_code, response.content.decode('utf-8')))
                break

    def __namespace_wise_utilization_dict(self, result, usage_percentages):
          return({
            "namespace": result['namespace'],
            "utilization": max(list(usage_percentages.values())),
            "utilization_unit": "percent",
            "node_id": result["node_id"],
            "details": usage_percentages
          })

    def __build_namespace_result(self, namespace_wise_utilization_dict):
        self.name_space_wise_response.append(namespace_wise_utilization_dict)

    def __build_node_id_wise_result(self, node_id, node_name, namespace_wise_utilization_dict):
        existing_node_record = next((node_detail for node_detail in self.node_id_wise_reponse if node_detail['node_id'] == node_id), None)
        namespace_wise_utilization_dict.pop('node_id', 'key_not_found') # removing the node_id from inner dict
        # If the node details already present in `node_id_wise_reponse` then update utilization_detail by appending namespace wise response
        # If not found then build new dict and append it directly to `node_id_wise_reponse`
        if existing_node_record == None:
            new_node_record = {
                "node_id": node_id,
                "node_name": node_name,
                "utilization_detail": [namespace_wise_utilization_dict]
            }
            self.node_id_wise_reponse.append(new_node_record)
        else:
            namespace_utilization = next((item for item in existing_node_record['utilization_detail'] if item["namespace"] == namespace_wise_utilization_dict["namespace"]), None)
            if namespace_utilization == None:
                existing_node_record['utilization_detail'].append(namespace_wise_utilization_dict)
            else:
                existing_node_record['utilization_detail'].remove(namespace_utilization)
                percentage_keys = ["cpu_usage_percentage", "memory_usage_percentage", "cpu_request_percentage", "memory_request_percentage"]
                percentage_details = { key: round(namespace_utilization['details'].get(key,0) + namespace_wise_utilization_dict['details'].get(key,0), 4) for key in percentage_keys }
                new_namespace_wise_utilization_dict = {
                    "namespace": namespace_wise_utilization_dict['namespace'],
                    "utilization": max([percentage_details[i] for i in percentage_details]),
                    "utilization_unit": "percent",
                    "details": percentage_details
                }
                existing_node_record['utilization_detail'].append(new_namespace_wise_utilization_dict)

    def __metric_usage_percentage(self, metrics):
        capacity_details = next((capacity_detail for capacity_detail in self.capacity_map_array if(capacity_detail['node_id'] == metrics['node_id'] and capacity_detail['namespace'] == metrics['namespace'] and capacity_detail['pod_name'] == metrics['pod_name'])), None)
        percentages = {
          "cpu_usage_percentage": self.__calculate_percentage(capacity_details['node_capacity_cpu'], metrics['pod_usage_cpu'], capacity_details['node_capacity_cpu_unit'], metrics['pod_usage_cpu_unit']),
          "memory_usage_percentage": self.__calculate_percentage(capacity_details['node_capacity_memory'],metrics['pod_usage_memory'],  capacity_details['node_capacity_memory_unit'], metrics['pod_usage_memory_unit']),
          "cpu_request_percentage": self.__calculate_percentage(capacity_details['node_capacity_cpu'], metrics['pod_request_cpu'], capacity_details['node_capacity_cpu_unit'], metrics['pod_request_cpu_unit']),
          "memory_request_percentage": self.__calculate_percentage(capacity_details['node_capacity_memory'], metrics['pod_request_memory'], capacity_details['node_capacity_memory_unit'], metrics['pod_request_memory_unit'])
        }
        return percentages

    def __calculate_percentage(self, capacity, actual_usage, capacity_unit, actual_usage_unit):
        capacity = float(capacity)
        actual_usage = float(actual_usage)
        try:
            if actual_usage_unit == 'milicores':
                actual_usage = self.__convert_milicores_to_cores(actual_usage)
            if actual_usage_unit == 'MiB':
                actual_usage = self.__convert_mb_to_gb(actual_usage)
            return round(((actual_usage / capacity) * 100), 4)
        except ZeroDivisionError:
            return 0.0

    def __convert_milicores_to_cores(self, milicores):
        return (milicores / 1000)

    def __convert_mb_to_gb(self, mb):
        return (mb / 1024)

payload = {
        "date_range": {
            "start_date": CloudBoltConstants.START_DATE,
            "end_date": CloudBoltConstants.END_DATE
        },
        "dimensions": [
            "namespace",
            "node_id",
            "node_name",
            "pod_name",
            "pod_usage_cpu_unit",
            "pod_request_cpu_unit",
            "pod_usage_memory_unit",
            "pod_request_memory_unit",
        ],
        "metrics": [
            "pod_usage_cpu",
            "pod_request_cpu",
            "pod_usage_memory",
            "pod_request_memory"
        ],
        "page_size": 1000
    }

capacity_payload = {
        "date_range": {
            "start_date": CloudBoltConstants.START_DATE,
            "end_date": CloudBoltConstants.END_DATE
        },
        "dimensions": [
            "namespace",
            "pod_name",
            "node_name",
            "node_id",
            "node_capacity_cpu_unit",
            "node_capacity_memory_unit"
        ],
        "metrics": [
            "node_capacity_cpu",
            "node_capacity_memory"
        ],
        "page_size": 1000
    }
obj = CloudBoltOpenshiftMetrics()
obj.save_capacity_data(capacity_payload)
obj.request_openshift_report_api(payload)
final_response = {
  "request_payload": payload,
  "response": obj.node_id_wise_reponse
}
logger.info("successfully calculated all the data, please find the result below \n Result data set :\n {}".format(json.dumps(final_response)))
