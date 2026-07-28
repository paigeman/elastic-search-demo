package com.example.course13;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import co.elastic.clients.elasticsearch.core.SearchResponse;
import co.elastic.clients.elasticsearch.core.search.Hit;
import java.io.IOException;
import java.util.Set;
import java.util.stream.Collectors;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

@EnabledIfEnvironmentVariable(named = "RUN_ES_INTEGRATION_TESTS", matches = "true")
class SearchProductsIntegrationTest {

  @Test
  void searchesInitializedCourseDatasetThroughProductionClient() throws IOException {
    SearchResponse<Product> filtered = SearchProducts.searchProducts("无线键盘", "keyboard", 20);
    assertEquals(Set.of("p1301", "p1302", "p1305"), hitIds(filtered));
    assertMappedWhitelistFields(filtered);

    SearchResponse<Product> withoutCategory = SearchProducts.searchProducts("键盘", 20);
    assertEquals(Set.of("p1301", "p1302", "p1304", "p1305"), hitIds(withoutCategory));
    assertMappedWhitelistFields(withoutCategory);
  }

  private static Set<String> hitIds(SearchResponse<Product> response) {
    return response.hits().hits().stream().map(Hit::id).collect(Collectors.toSet());
  }

  private static void assertMappedWhitelistFields(SearchResponse<Product> response) {
    for (Hit<Product> hit : response.hits().hits()) {
      Product product = hit.source();
      assertNotNull(product);
      assertEquals(hit.id(), product.getProductId());
      assertNotNull(product.getName());
      assertTrue(product.getPrice() > 0);
      assertTrue(product.getStock() >= 0);
      assertNull(product.getDescription());
      assertNull(product.getCategory());
      assertFalse(product.isAvailable());
    }
  }
}
