"""Import OKFN "aggregates" exports (XML inside ZIP) into the gazettes index.

The aggregates are the public bulk export of Querido Diário: one ZIP per state
and year (aggregates/{UF}/{UF}_{year}.zip) holding one XML per municipality with
the already-extracted text of every gazette. Importing them seeds the fallback
index with history without crawling or running Tika.

Runs inside the api container (it already has opensearch-py):
    python deploy/fallback/bin/import_aggregates.py /imports/AL_2024.zip [...]

Optional: --territories 2704302,2700706 to import only those IBGE codes.
Re-running is safe: document ids are derived from the content.
"""

import argparse
import hashlib
import os
import sys
import zipfile
from datetime import datetime
from xml.etree.ElementTree import iterparse

import opensearchpy
from opensearchpy.helpers import streaming_bulk

INDEX = os.environ.get("GAZETTE_OPENSEARCH_INDEX", "querido-diario")


def text(element, path):
    found = element.find(path)
    return (found.text or "").strip() if found is not None else ""


def gazettes_from_xml(stream, territories):
    meta = {}
    for _, element in iterparse(stream, events=("end",)):
        if element.tag == "meta":
            meta = {
                "state_code": text(element, "uf"),
                "territory_name": text(element, "municipio"),
                "territory_id": text(element, "municipio_codigo_ibge"),
            }
            if territories and meta["territory_id"] not in territories:
                return
        elif element.tag == "diario":
            content = text(element, "conteudo")
            published = datetime.strptime(
                text(element, "meta_diario/data_publicacao"), "%d/%m/%Y"
            ).date()
            checksum = hashlib.sha1(
                f"{meta['territory_id']}|{published}|".encode() + content.encode()
            ).hexdigest()
            yield {
                "_index": INDEX,
                "_id": checksum,
                **meta,
                "date": published.isoformat(),
                # The export has no crawl timestamp; the publication date is the
                # closest stand-in and keeps scraped_since filters meaningful.
                "scraped_at": f"{published.isoformat()}T00:00:00",
                "url": text(element, "meta_diario/url_arquivo_original"),
                "file_checksum": checksum,
                "edition_number": text(element, "meta_diario/numero_edicao") or None,
                "is_extra_edition": text(element, "meta_diario/edicao_extra") == "Sim",
                "power": text(element, "meta_diario/poder") or None,
                "source_text": content,
                "processed": True,
            }
            element.clear()


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("zips", nargs="+")
    parser.add_argument("--territories", default="")
    args = parser.parse_args()
    territories = {t for t in args.territories.split(",") if t}

    client = opensearchpy.OpenSearch(
        hosts=[os.environ["QUERIDO_DIARIO_OPENSEARCH_HOST"]], timeout=120
    )
    if not client.indices.exists(index=INDEX):
        sys.exit(f"index {INDEX} missing: run bin/seed.sh, which creates it first")

    total = 0
    for path in args.zips:
        with zipfile.ZipFile(path) as archive:
            for name in archive.namelist():
                if not name.endswith(".xml"):
                    continue
                with archive.open(name) as stream:
                    count = 0
                    for ok, result in streaming_bulk(
                        client,
                        gazettes_from_xml(stream, territories),
                        chunk_size=50,
                        max_chunk_bytes=50 * 1024 * 1024,
                        raise_on_error=False,
                    ):
                        if ok:
                            count += 1
                        else:
                            print(f"  failed: {result}", file=sys.stderr)
                    if count:
                        print(f"{path}:{name}: {count} gazettes")
                    total += count
    print(f"imported {total} gazettes")


if __name__ == "__main__":
    main()
