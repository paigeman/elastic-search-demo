import json
import os

from elasticsearch import Elasticsearch

INDEX_NAME = "application-client-products-read"

client = Elasticsearch(
    os.environ["ES_URL"],
    ca_certs=os.environ["ES_CA"],
    api_key=os.environ["ES_API_KEY"],
    request_timeout=2,
    max_retries=3,
    retry_on_timeout=True,
)


def search_products(
    keyword: str,
    category: str | None,
    page_size: int = 20,
):
    page_size = min(max(page_size, 1), 100)
    filters = [{"term": {"available": True}}]
    if category:
        filters.append({"term": {"category": category}})

    response = client.search(
        index=INDEX_NAME,
        size=page_size,
        source=["product_id", "name", "price", "stock"],
        query={
            "bool": {
                "must": [
                    {
                        "multi_match": {
                            "query": keyword,
                            "fields": ["name^3", "description"],
                        }
                    }
                ],
                "filter": filters,
            }
        },
    )
    return response.body


if __name__ == "__main__":
    try:
        result = search_products("无线键盘", category="keyboard")
        print(json.dumps(result, ensure_ascii=False, indent=2))
    finally:
        client.close()
