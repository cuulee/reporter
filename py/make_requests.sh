#!/bin/bash
trap "kill 0" EXIT
which parallel &> /dev/null
if [ $? != 0 ]; then
        echo "parallel is required please install it"
        echo "sudo apt-get install parallel"
        exit 1
fi
set -e

function usage {
  echo -e "Usage:\n-s s3 bucket url\n-f regex to use with grep to get interesting files\n" 1>&2
  echo "Example: AWS_DEFAULT_PROFILE=opentraffic $0 -s s3://heaps_of_data/2016_11/ -f 2016_11_01.*gz -b 172.17.0.1:9092 -t mytopic -w 300 -j 1" 1>&2
  echo "Note: bucket listing is not recursive" 1>&2
  echo "Note: data is pipe delimited: date|id|x|x|x|x|x|x|x|lat|lon|x|x with date format: %Y-%m-%d %H:%M:%S" 1>&2
  exit 1
}

function work {
  file=${1}
  echo "Retrieving ${file} from s3" && aws s3 cp ${s3_dir}${file} . &> /dev/null
  #send to kafka producer
  zcat ${file} | sort | ./cat_to_kafka.py --bootstrap ${bootstrap} --topic ${topic} --key-with "${key_with}" --value-with "${value_with}" -
  #wait around a little for the system to process it
  sleep ${timeout}
  #done with this
  echo "Finished producing ${file}" && rm -f ${file}
}
export -f work

timeout=0
parallel=1
while getopts ":s:f:b:t:w:j:" opt; do
  case $opt in
    s) s3_dir=$(echo ${OPTARG} | sed -e 's@/\?$@/@g')
    ;;
    f) file_re="${OPTARG}"
    ;;
    b) bootstrap="${OPTARG}"
    ;;
    t) topic="${OPTARG}"
    ;;
    w) timeout="${OPTARG}"
    ;;
    j) parallel="${OPTARG}"
    ;;
    \?) echo "Invalid option -${OPTARG}" 1>&2 && usage
    ;;
  esac
done

hash=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
export key_with='lambda line: line.split("|")[1]'
export value_with="lambda line: re.sub(r'^([^\\|]+)\\|', r'\\1|${hash}', line)"
export s3_dir bootstrap topic timeout parallel

if [[ -z ${s3_dir} ]] || [[ -z ${file_re} ]] || [[ -z ${bootstrap} ]] || [[ -z ${topic} ]]; then
  echo "Missing required option" 1>&2 && usage
fi

#get all the list of files we'll be working with
echo "Retrieving file list from s3"
files=$(aws s3 ls ${s3_dir} | awk '{print $4}' | grep -E ${file_re} | tr '\n' ' ')
echo "Processing $(echo ${files} | tr ' ' '\n' | wc -l) files with ${parallel} processes"
echo ${files} | xargs -n1 -P${parallel} bash -c 'work "$@"' _
