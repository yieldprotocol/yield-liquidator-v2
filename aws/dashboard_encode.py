import urllib.parse as UP
import json
import sys

def main(data):
    print("widgetDefinition=%s" % UP.quote(json.dumps(json.loads(data))))

if __name__ == "__main__":
    main(sys.stdin.read())