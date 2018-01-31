// Upgrade NOTE: replaced '_Object2World' with 'unity_ObjectToWorld'

Shader "RxShaderLab/SimpleWaterShader" {

	Properties {

		_Color ("Tint Color", Color) = (0, 0.627, 1, 0.5)
		_Glossiness ("Smoothness", Range(0,1)) = 0.8
		_Metallic ("Metallic", Range(0,1)) = 0.09
		
		_Overall_Speed ("Overall Speed", Float) = 1.0

		// Albedo texture
		_MainTex ("Albedo Texture (RGB)", 2D) = "white" {}
		_MainTex_Params ("Albedo Params(inten, dist, speed)", Vector) = (0.35, 0.9, 0.05, 0.07)
		[MaterialToggle(_TEX_STATIC)] _StaticAlbedo("Static Albedo Map", Float) = 0

		// Wave normal
		_Bump ("Wave (Normal)", 2D) = "bump" {}
		_BigWave_Tiling_X ("Big Wave Tiling-X", Float) = 2
		_BigWave_Tiling_Y ("Big Wave Tiling-Y", Float) = 2
		_WaveSpeed ("Wave Speed (med, big)", Vector) = (0.5, 0.8, -0.2, 0.4) // (Medium Wave Speed, Big Wave Speed)
		_Weight_1("Medium Wave Blend", Float) = 0.35
		_Weight_2 ("Big Wave Blend", Float) = 0.55

		_Normal_Intensity ("Normal Intensity", Range(0,2)) = 1.0
		
		// Depth blending and foam
		[MaterialToggle(_ENABLE_DBLEND)] _EnableDepthBlend("Enable Depth Blending", Float) = 0
		_InvFadeParemeter ("Blending Parameter", Vector) = (0.15 ,0.15, 0.5, 1.0)
		_FoamTex ("Foam Texture", 2D) = "white" {}
		_Foam ("Foam (inten, cutoff, speed)", Vector) = (0.4, 0.5, 0.0, 0.0)

		// Noise texture
		[NoScaleOffset] _DitherMap ("Distortion Map (R)", 2D) = "white" {}

		// Refraction and reflection
		[MaterialToggle(_ENABLE_REFRACTION)] _EnableRefraction("Refraction (Not Implemented)", Float) = 0
		_Refractive_Index ("Refractive Index (Not Implemented)", Float) = 1.33

		[MaterialToggle(_ENABLE_REFLECTION)] _EnableReflection("Reflection", Float) = 0
		[MaterialToggle(_BOX_REFLECTION)] _BoxReflection("Box Reflection", Float) = 0
		_Reflection_Alpha ("Reflection Alpha", Range(0,1)) = 0.6
		_Skybox_Alpha ("Skybox Alpha", Range(0,2)) = 1
		[NoScaleOffset] _SkyCubemap("Skybox Cubemap", CUBE) = "" {}

		// Vertex wave
		[MaterialToggle(_ENABLE_WAVE)] _EnableWave("Enable Vertex Wave", Float) = 0
		_VWaveParameter ("Vertex Wave Parameter (speed, amp, freq, dist)", Vector) = (0.3 ,0.35, 0.25, 0.25)
	}

	SubShader {

		Tags { "RenderType"="Transparent" "Queue" = "Transparent" "IgnoreProjector" = "True" }
		LOD 300 // Bumped, Specular

		//Cull Off
		CGPROGRAM

		#pragma surface surf Standard_Water vertex:vert alpha noshadow finalcolor:envColor
		#include "UnityPBSLighting.cginc"
		#include "UnityCG.cginc"

		// Need shader model 3.0 support
		#pragma target 3.0

		#pragma multi_compile _ENABLE_DEPTH_TEXTURE
		
		#pragma shader_feature _TEX_STATIC	
		#pragma shader_feature _ENABLE_DBLEND
		#pragma shader_feature _ENABLE_REFLECTION	
		#pragma shader_feature _BOX_REFLECTION
		//#pragma shader_feature _ENABLE_REFRACTION	
		#pragma shader_feature _ENABLE_WAVE

		sampler2D _MainTex;
		sampler2D _Bump;
		sampler2D _DitherMap;

		#if defined(_ENABLE_DBLEND) && defined(_ENABLE_DEPTH_TEXTURE)
		sampler2D_float _CameraDepthTexture;
		sampler2D _FoamTex;
		#endif

		#ifdef _ENABLE_REFLECTION
		half _Reflection_Alpha;
			#ifdef _BOX_REFLECTION
			half _Skybox_Alpha;
			samplerCUBE _SkyCubemap;
			#endif
		#endif

		struct Input
		{
			#if defined(_ENABLE_DBLEND) || defined(_ENABLE_REFLECTION)
			float3 localPos;
			#endif

			#ifdef _ENABLE_REFLECTION
			float3 worldPos;
			#endif

			float2 uv_MainTex;
			float2 uv_Bump;
			float2 uv_DitherMap;
			float2 uv_FoamTex;
		};

		struct SurfaceOutputStandard_Water
		{
			fixed3 Albedo;      // Base (diffuse or specular) color
			fixed3 Normal;      // Tangent space normal
			half3 Emission;
			half Metallic;      // 0 = non-metal, 1 = metal
								// Smoothness is the user facing name, it should be perceptual smoothness but user should not have to deal with it.
								// Everywhere in the code you meet smoothness it is perceptual smoothness
			half Smoothness;    // 0 = rough, 1 = smooth
			half Occlusion;     // Occlusion (default 1)
			fixed Alpha;        // Alpha for transparencies

			#if defined(_ENABLE_DBLEND) && defined(_ENABLE_DEPTH_TEXTURE)
			float4 ref;			// Screen space coordinates
			half3 bumpCoord;
			#endif

			#ifdef _ENABLE_REFLECTION
			float3 worldPos;	// World vertex position, for reflection usage
			#endif					
		};

		fixed4 _Color;

		#if defined(_ENABLE_DBLEND) && defined(_ENABLE_DEPTH_TEXTURE)
		half4 _InvFadeParemeter;
		half4 _Foam;
		#endif

		half _Overall_Speed;

		half4 _MainTex_Params;

		half _Glossiness;
		half _Metallic;	

		half4 _WaveSpeed;
		
		half _BigWave_Tiling_X;
		half _BigWave_Tiling_Y;

		half _Weight_1;
		half _Weight_2;

		half _Normal_Intensity;
		
		#ifdef _ENABLE_WAVE
		half4 _VWaveParameter;
		#endif

		// Calibrate box reflection probe's reflection direction
		inline half3 BoxProjection(half3 direction, half3 position, half3 cubemapPosition, half3 boxMin, half3 boxMax)
		{
			half3 factors = ((direction > 0 ? boxMax : boxMin) - position) / direction;
			half scalar = min(min(factors.x, factors.y), factors.z);
			return direction * scalar + (position - cubemapPosition);
		}

		// Custom lighting model based on Standard Model
		inline half4 LightingStandard_Water(SurfaceOutputStandard_Water s, half3 viewDir, UnityGI gi)
		{
			s.Normal = normalize(s.Normal);

			half oneMinusReflectivity;
			half3 specColor;
			s.Albedo = DiffuseAndSpecularFromMetallic(s.Albedo, s.Metallic, /*out*/ specColor, /*out*/ oneMinusReflectivity);

			// Shader relies on pre-multiply alpha-blend (_SrcBlend = One, _DstBlend = OneMinusSrcAlpha)
			// This is necessary to handle transparency in physically correct way - only diffuse component gets affected by alpha
			half outputAlpha;
			s.Albedo = PreMultiplyAlpha(s.Albedo, s.Alpha, oneMinusReflectivity, /*out*/ outputAlpha);

			half4 c = UNITY_BRDF_PBS(s.Albedo, specColor, oneMinusReflectivity, s.Smoothness, s.Normal, viewDir, gi.light, gi.indirect);
			c.a = outputAlpha;

			// Custom reflection using specular cubemap
			#ifdef _ENABLE_REFLECTION
	
				half3 skyReflection = reflect(-viewDir, s.Normal);

				#ifdef _BOX_REFLECTION 
					half3 reflectionDir = BoxProjection(
						skyReflection, s.worldPos,
						unity_SpecCube0_ProbePosition,
						unity_SpecCube0_BoxMin, unity_SpecCube0_BoxMax
					);
				#else
					half3 reflectionDir = skyReflection;
				#endif

				half4 hdrReflection = UNITY_SAMPLE_TEXCUBE_LOD(unity_SpecCube0, reflectionDir, 0); // The last paramter is reflection roughness
				fixed4 reflection = 1.0;
				reflection.rgb = DecodeHDR(hdrReflection, unity_SpecCube0_HDR); // Convert the samples from HDR format to RGB

				#ifdef _BOX_REFLECTION 
					// Blend with skybox
					reflection.rgb += lerp(
						0, 
						texCUBE(_SkyCubemap, skyReflection) * (_Skybox_Alpha * _Reflection_Alpha), 
						1 - max(step(0.01, reflection.r), max(step(0.01, reflection.g), step(0.01, reflection.b))) // Fill black area (where it should be skybox)
					);
				#endif

				reflection.a = 1.0;

				c.rgb = lerp(
					c.rgb, 
					c.rgb * (1 - _Reflection_Alpha) + reflection.rgb * _Reflection_Alpha,
					c.a);

			#endif

			return c;
		}

		// Necessary GI Function
		inline void LightingStandard_Water_GI(SurfaceOutputStandard_Water s, UnityGIInput data, inout UnityGI gi)
		{
			#if defined(UNITY_PASS_DEFERRED) && UNITY_ENABLE_REFLECTION_BUFFERS
				gi = UnityGlobalIllumination(data, s.Occlusion, s.Normal);
			#else
				Unity_GlossyEnvironmentData g = UnityGlossyEnvironmentSetup(s.Smoothness, data.worldViewDir, s.Normal, lerp(unity_ColorSpaceDielectricSpec.rgb, s.Albedo, s.Metallic));
				gi = UnityGlobalIllumination(data, s.Occlusion, s.Normal, g);
			#endif
		}

		void surf(Input IN, inout SurfaceOutputStandard_Water o)
		{		
			float2 offset;
			half3 normalAddOn;

			// Albedo texture sampling
			offset.x = _MainTex_Params.z * _Time;
			offset.y = _MainTex_Params.w * _Time;
			offset *= _Overall_Speed;
			#ifdef _TEX_STATIC
				o.Albedo = (tex2D(_MainTex, IN.uv_MainTex + tex2D(_DitherMap, IN.uv_DitherMap - offset).xy * _MainTex_Params.y) 
					* _MainTex_Params.x 
					+ _Color).rgb;
			#else
				o.Albedo = (tex2D(_MainTex, IN.uv_MainTex - offset + tex2D(_DitherMap, IN.uv_DitherMap).xy * _MainTex_Params.y) 
					* _MainTex_Params.x 
					+ _Color).rgb;
			#endif
			o.Alpha = _Color.a;

			o.Metallic = _Metallic;
			o.Smoothness = _Glossiness;		

			// Medium wave sampling
			offset.x = _WaveSpeed.x * _Time;
			offset.y = _WaveSpeed.y * _Time;
			offset *= _Overall_Speed;
			normalAddOn = UnpackNormal(tex2D(_Bump, IN.uv_Bump - offset));
			normalAddOn.x *= _Weight_1;
			normalAddOn.y *= _Weight_1;
			o.Normal += normalAddOn;

			// Big wave sampling
			offset.x = _WaveSpeed.z * _Time;
			offset.y = _WaveSpeed.w * _Time;
			offset *= _Overall_Speed;
			// CAUTION: calibrate using distortion map's UV
			normalAddOn = UnpackNormal(tex2D(_Bump, half2(IN.uv_DitherMap.x * _BigWave_Tiling_X, IN.uv_DitherMap.y * _BigWave_Tiling_Y) - offset)) * _Weight_2;
			normalAddOn.x *= _Weight_2;
			normalAddOn.y *= _Weight_2;
			o.Normal += normalAddOn;

			o.Normal.x *= _Normal_Intensity;
			o.Normal.y *= _Normal_Intensity;
			
			#if defined(_ENABLE_DBLEND) && defined(_ENABLE_DEPTH_TEXTURE)
			
				o.ref = ComputeNonStereoScreenPos(UnityObjectToClipPos(IN.localPos));
				
				// Foam texture sampling
				offset.x = _Foam.z * _Time;
				offset.y = _Foam.w * _Time;		
				fixed4 dither = tex2D(_DitherMap, IN.uv_DitherMap * 2 - offset.xy);
				offset *= _Overall_Speed;
				o.bumpCoord = half3(IN.uv_FoamTex + offset.xy + dither.xy, dither.r * dither.r * dither.r);
				
			#endif

			#ifdef _ENABLE_REFLECTION
				o.worldPos = IN.worldPos;
			#endif
		}
		
		// Custom vertex program
		void vert(inout appdata_full v, out Input o)
		{
			UNITY_INITIALIZE_OUTPUT(Input, o);

			// Retrieve vertex position
			#if defined(_ENABLE_DBLEND) || defined(_ENABLE_REFLECTION)
				o.localPos = v.vertex.xyz;
			#endif

			#ifdef _ENABLE_REFLECTION
				o.worldPos = mul(unity_ObjectToWorld, (v.vertex)).xyz;
			#endif

			// Vertex wave
			#ifdef _ENABLE_WAVE

				#ifdef _ENABLE_REFLECTION
					half3 worldSpaceVertex = o.worldPos;
				#else
					half3 worldSpaceVertex = mul(unity_ObjectToWorld, (v.vertex)).xyz;
				#endif

				half waveHeight = sin((v.vertex.x + v.vertex.z) * _VWaveParameter.z 
				+ _Time.y * _VWaveParameter.x * _VWaveParameter.z) 
				* _VWaveParameter.y;
				
				half distort = tex2Dlod(_DitherMap, 
				half4(_VWaveParameter.w, _VWaveParameter.w, 0, 0) * _Time.x).r 
				* _VWaveParameter.w;
				
				v.vertex.xyz += waveHeight * distort * v.normal;
				
			#endif
		}

		void envColor(Input IN, SurfaceOutputStandard_Water s, inout fixed4 color)
		{
			// Depth color blending
			#if defined(_ENABLE_DBLEND) && defined(_ENABLE_DEPTH_TEXTURE)

				half depth = SAMPLE_DEPTH_TEXTURE_PROJ(_CameraDepthTexture, UNITY_PROJ_COORD(s.ref));
				depth = LinearEyeDepth(depth);
				half BlendFactor = 1.0;
				BlendFactor = saturate(_InvFadeParemeter * (depth - s.ref.w)).x;
				color.a = BlendFactor * saturate(_InvFadeParemeter.z + color.a);
				
				// Foam
				half4 foam = tex2D(_FoamTex, s.bumpCoord.xy);
				color.rgb += foam.rgb * _Foam.x * saturate(1 - color.a * color.a - _Foam.y) * s.bumpCoord.z;
				
			#endif
		}
		
		ENDCG
	}

	// Simplified sub-shader for lower LOD
	SubShader{

		Tags{ "RenderType" = "Transparent" "Queue" = "Transparent" "IgnoreProjector" = "True" }
		LOD 150 // Decal, Reflective VertexLit

		CGPROGRAM

		#pragma surface surf SimpleLambert alpha noshadow

		#pragma target 3.0

		#pragma shader_feature _TEX_STATIC

		sampler2D _MainTex;
		sampler2D _DitherMap;

		struct Input
		{
			float2 uv_MainTex;
			float2 uv_DitherMap;
		};

		fixed4 _Color;

		half _MainTex_Intensity;
		half _MainTex_Dither_Intensity;

		half _MainTex_Speed_X;
		half _MainTex_Speed_Y;

		half _Overall_Speed;

		half _Dither_Intensity;

		// No specular
		inline fixed4 LightingSimpleLambert(SurfaceOutput s, half3 lightDir, half atten)
		{
			fixed diff = max(0, dot(s.Normal, lightDir));
			fixed4 c;
			c.rgb = s.Albedo * _LightColor0.rgb * (diff * atten * 2);
			c.a = s.Alpha;
			return c;
		}

		void surf(Input IN, inout SurfaceOutput o)
		{
			float2 offset;

			// Albedo texture sampling only
			offset.x = _MainTex_Speed_X * _Time;
			offset.y = _MainTex_Speed_Y * _Time;
			offset *= _Overall_Speed;
			#ifdef _TEX_STATIC
				o.Albedo = ((tex2D(_MainTex, IN.uv_MainTex + tex2D(_DitherMap, IN.uv_DitherMap - offset).xy * _MainTex_Dither_Intensity) 
					+ _Color) 
					* _MainTex_Intensity).rgb;
			#else
				o.Albedo = ((tex2D(_MainTex, IN.uv_MainTex - offset + tex2D(_DitherMap, IN.uv_DitherMap).xy * _MainTex_Dither_Intensity) 
					+ _Color) 
					* _MainTex_Intensity).rgb;
			#endif
			o.Alpha = _Color.a;
		}
		ENDCG
	}

	FallBack "Diffuse"
}
