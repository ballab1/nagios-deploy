#!/usr/bin/python
#  -*- coding: utf-8 -*-

"""
producer

This script will be run at command line to produce message to a topic

See the usage method for more information and examples.

"""
# Imports: native Python
import argparse
import sys
import socket
import json
import time
import logging
import logging.handlers
import datetime
import random
from uuid import uuid1

# 3rd party imports
from confluent_kafka import Producer, Consumer, KafkaError, OFFSET_BEGINNING, OFFSET_END, OFFSET_STORED, OFFSET_INVALID


class KProducer(object):
    """
        KProducer class
    """

    def __init__(self):
        """
        Constructor
            Create a Producer.

        Returns:
            A new instance of the KProducer class
        """
        self.logger = logging.getLogger(__name__)
        self.logger.setLevel(logging.DEBUG)
        # create file handler which logs even debug messages
        fh = logging.FileHandler('spam.log')
        fh.setLevel(logging.DEBUG)
        # create console handler with a higher log level
        ch = logging.StreamHandler()
        ch.setLevel(logging.ERROR)
        # create formatter and add it to the handlers
        formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
        fh.setFormatter(formatter)
        ch.setFormatter(formatter)
        # add the handlers to the logger
        self.logger.addHandler(fh)
        self.logger.addHandler(ch)

    def usage(self):
        """
        Description:
            Display examples for the user.

        Returns:
            None
        """
        examples = """
        This script will produce message to topics for a specific purpose.

            python producer.py \
                --server 127.0.0.1:9092 \
                --topic job_request_test \
                --value '[{"request_id":"unknown","request_filters":"unknown","job_master":"unknown","job_slave":"unknown","job_build_id":"unknown","job_status_url":"unknown","repo_url":["someurl"],"docker_label":"unknown","docker_command":"unknown","job_definition_path":"unknown","payload":"unknown","request_type":"automatos","request_status":"new"}]'

        """
        return examples

    def getargs(self):
        """
        Description:
            Parse the arguments given on command line.

        Returns:
            Namespace containing the arguments to the command. The object holds the argument
            values as attributes, so if the arguments dest is set to "myoption", the value
            is accessible as args.myoption
        """
        # parse any command line arguments
        p = argparse.ArgumentParser(description='KProducer client',
                                    epilog=self.usage(),
                                    formatter_class=argparse.RawDescriptionHelpFormatter)
        p.add_argument('-t', '--topic', required=True, help='The topic to consume from (default: test-transitj)')
        p.add_argument('-v', '--value', help='Value')
        p.add_argument('-k', '--key', help='Key')
        p.add_argument('-s', '--server', required=True, help='Kafka server')

        args = p.parse_args()

        return args

    def validate_options(self, args):
        """
        Description:
            Validate the correct arguments are provided and that they are the correct type

        Raises:
            ValueError: If request_type or request_status are not one of the acceptable values
        """

        if args.topic is None:
            raise ValueError("You must provide a topic to log data to")

        if args.value is None and args.key is None:
            raise ValueError("You should specify either a value or a key to be published to a topic")

    def zulu_timestamp(self):
        return datetime.datetime.utcnow().strftime("%Y-%m-%dT%I:%M:%S.%fZ")

    def uuid1mc_insecure(self):
        return str(uuid1(random.getrandbits(48) | 0x010000000000))

    def _create_kafka_producer(self, server):
        """
        Description:
            Creates the Confuent-Kafka Producer to produce message

        Args:
            server (text_type): Kafka server

        Return:
            An instance of Producer
        """
        # bootstrap.servers  - A list of host/port pairs to use for establishing the initial connection to the Kafka cluster
        # client.id          - An id string to pass to the server when making requests
        producer = Producer({"bootstrap.servers": server,
                             "client.id": socket.gethostname()})
        return producer


    def produce(self, server, topic, value=None, key=None):
        """
        Description:
            Produce a message to a topic

        Args:
            server (text_type): Kafka server
            topic (text_type): The topic to consume from
            value (text_type, optional): Message payload
            key (text_type, optional): Message key

        Return
            None
        """

        # Convert value and key to utf-8 format
        json_objects = json.loads(value)
        json_objects['timestamp'] = self.zulu_timestamp()
        json_objects['uuid'] = self.uuid1mc_insecure()

        input_data = dict()
        input_data["topic"] = topic
        producer = self._create_kafka_producer(server)

        input_data["value"] = json.dumps(json_objects)
        input_data["key"] = key

        self.logger.debug("Input Data to produce: \n %s" % input_data)
        producer.produce(**input_data)
        # flush() - Wait for all messages in the Producer queue to be delivered
        producer.flush()


    def main(self, args):
        """
        Run the code.  See the usage function for more info.
        """
        self.logger.debug("Entering main with args: %s" % args)
        args = self.getargs()
        self.validate_options(args)

        self.produce(args.server, args.topic, args.value, args.key)
        self.logger.info("Message was successfully published to the topic %s" % args.topic)
        return 0

# ### ----- M A I N   D R I V E R   C O D E ----- ### #


if __name__ == "__main__":
    av = KProducer()
    main_result = av.main(sys.argv[1:])
    sys.exit(main_result)
