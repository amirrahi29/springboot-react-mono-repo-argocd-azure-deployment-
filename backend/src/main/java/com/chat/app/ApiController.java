package com.chat.app;

import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api")
public class ApiController {

	@GetMapping(value = "/healthz", produces = MediaType.APPLICATION_JSON_VALUE)
	public Map<String, String> healthz() {
		return Map.of("status", "ok");
	}

	@GetMapping(value = "/data", produces = MediaType.APPLICATION_JSON_VALUE)
	public Map<String, Object> data() {
		Map<String, Object> body = new LinkedHashMap<>();
		body.put("message", "Sample data");
		body.put("items", List.of(Map.of("id", 1, "name", "Alpha"), Map.of("id", 2, "name", "Beta")));
		body.put("timestamp", Instant.now().toString());
		return body;
	}
}
