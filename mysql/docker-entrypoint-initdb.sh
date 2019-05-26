#!/bin/bash

function loadDb()
{
  local -r datafile=$1
  local -r dbname=$(basename "$datafile" .sql)
  local sqlcmd=( "${mysql[@]}" )
  echo "Loading ${dbname} from ${datafile}"
  echo "create database if not exists ${dbname};" | "${sqlcmd[@]}"
  echo "source ${datafile}" | "${sqlcmd[@]}" "$dbname"
}


declare -r cwd=$( dirname "${BASH_SOURCE[0]}" )
declare mysql=( mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -hlocalhost )

for f in "${cwd}/dumps"/*; do
  case "$f" in
    *.sql)    loadDb "$f"; echo ;;
#    *.sql.gz) echo "$0: running $f"; gunzip -c "$f" | "${mysql[@]}"; echo ;;
    *)        echo "$0: ignoring $f" ;;
  esac
  echo
done
echo 'show databases;' | "${mysql[@]}"
